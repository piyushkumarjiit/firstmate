#!/bin/bash
set -euo pipefail
# The shebang is a direct /bin/bash on purpose: firstmate launches this wrapper
# through the bin/agy-pool/agy symlink, and with a single exec the kernel names
# the process after that path ("agy"). Herdr and firstmate identify a live agy
# worker by that process name; an /usr/bin/env hop would rename it to bash.

# ==============================================================================
# fm-agy-pool.sh
# Model-aware sticky quota router + live Google quota + local fallback telemetry
#
# Environment variables:
#   POOL_CONF             Pool account list (default /etc/firstmate/gpro-pool.conf)
#   MODELS_CONF           Legacy glob map (ignored; availability and Neon
#                         reservation come from per-account `agy models` caches)
#   AGY_BIN               Real agy binary (default /usr/local/bin/agy)
#   FM_AGY_STATE_DIR      Shared pool state dir (default /tmp/fm-agy-pool)
#   FM_AGY_USAGE_LOG      JSONL usage log (default /var/log/firstmate/agy-usage.jsonl)
#   FM_AGY_MIN_PCT        Minimum remaining pct floor (default 15)
#   FM_AGY_WINDOW_SEC     Fallback reset window seconds (default 18000)
#   FM_AGY_BUDGET_SEC     Fallback budget seconds (default 5400)
#   FM_AGY_MODELS_TTL     Model catalog cache TTL seconds (default 86400)
#   FM_AGY_PACING_SEC     Minimum seconds between live queries on different
#                         accounts under live-query.lock (default 60)
#   FM_AGY_LIVE_TIMEOUT   Seconds bound per live agy query (default 30)
#   FM_AGY_MAX_ACTIVE     Concurrent active pool account cap (default 2)
#
# JSONL usage log records (FM_AGY_USAGE_LOG; for FQD ingest without live calls):
#   1. event="usage_check" (selection start/skip/unknown and --usage manual):
#      {ts, provider, user, model, task, event, group, gemini_min_pct, reset,
#       weekly_pct, weekly_reset, five_hour_pct, five_hour_reset, decision}
#   2. event="quota_end" (live /usage reading after task completion):
#      {ts, provider, user, model, task, event, group, gemini_min_pct, reset,
#       weekly_pct, weekly_reset, five_hour_pct, five_hour_reset}
#   3. Run summary (no event field; backward compatible):
#      {ts, provider, user, model, task, duration_sec, exit_code,
#       est_remaining_pct, quota_hit}
# ==============================================================================

POOL_CONF="${POOL_CONF:-/etc/firstmate/gpro-pool.conf}"
# Legacy MODELS_CONF is ignored: model availability and Neon reservation come
# from each account's cached `agy models` catalog so stale config globs cannot
# restrict Hydrogen or override discovered models.
AGY_BIN="${AGY_BIN:-/usr/local/bin/agy}"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
STATE_DIR="${FM_AGY_STATE_DIR:-/tmp/fm-agy-pool}"
USAGE_LOG="${FM_AGY_USAGE_LOG:-/var/log/firstmate/agy-usage.jsonl}"
MIN_REMAINING_PCT="${FM_AGY_MIN_PCT:-15}"         # Switch accounts when <= 15% left
WINDOW_SECONDS="${FM_AGY_WINDOW_SEC:-18000}"       # Fallback 5-hour rolling window
DEFAULT_BUDGET_SEC="${FM_AGY_BUDGET_SEC:-5400}"    # Fallback budget (auto-calibrates on 429)
MODELS_TTL="${FM_AGY_MODELS_TTL:-86400}"           # 24h catalog cache TTL
PACING_SECONDS="${FM_AGY_PACING_SEC:-60}"          # Min gap across different accounts
LIVE_TIMEOUT="${FM_AGY_LIVE_TIMEOUT:-30}"          # Per-query timeout seconds
[[ "$MODELS_TTL" =~ ^[0-9]+$ ]] || MODELS_TTL=86400
[[ "$PACING_SECONDS" =~ ^[0-9]+$ ]] || PACING_SECONDS=60
[[ "$LIVE_TIMEOUT" =~ ^[0-9]+$ ]] || LIVE_TIMEOUT=30
TASK_LABEL="${FM_TASK_ID:-${PWD##*/}}"

# The --check-* spawn gates are read-only: they never create or touch pool state.
if [[ "${1:-}" != --check-* ]]; then
  umask 0002
  mkdir -p "$STATE_DIR"
  chmod 1777 "$STATE_DIR" 2>/dev/null || true
fi

if [[ -f "$POOL_CONF" ]]; then
  mapfile -t GPRO_USERS < <(grep -Ev '^\s*(#|$)' "$POOL_CONF" | awk '{print $1}')
else
  GPRO_USERS=()
fi

now_epoch() { date +%s; }

is_authenticated() {
  local user="$1"
  sudo -n -u "$user" test -s "/home/${user}/.gemini/antigravity-cli/antigravity-oauth-token" 2>/dev/null
}

init_or_roll_window() {
  local user="$1"
  local qfile="$STATE_DIR/${user}.state.json"
  local now
  now=$(now_epoch)

  if [[ ! -f "$qfile" ]]; then
    jq -n --arg u "$user" --argjson b "$DEFAULT_BUDGET_SEC" \
      '{user: $u, window_start: 0, reset_at: 0, used_sec: 0, budget_sec: $b, exhausted: false}' > "$qfile"
    chmod 0666 "$qfile" 2>/dev/null || true
    return
  fi

  local reset_at
  reset_at=$(jq -r '.reset_at // 0' "$qfile" 2>/dev/null || echo 0)
  if (( reset_at > 0 && now >= reset_at )); then
    local budget updated
    budget=$(jq -r ".budget_sec // $DEFAULT_BUDGET_SEC" "$qfile")
    updated=$(jq --arg u "$user" --argjson b "$budget" --argjson now "$now" \
      '{user: $u, window_start: 0, reset_at: 0, used_sec: 0, budget_sec: $b, exhausted: false}
       + (if .quota then {quota: (.quota | with_entries(select((.value.reset_at // 0) <= 0 or $now < (.value.reset_at // 0))))} else {} end)' \
      "$qfile" 2>/dev/null || true)
    if [[ -n "$updated" ]]; then
      printf '%s\n' "$updated" > "$qfile"
    else
      jq -n --arg u "$user" --argjson b "$budget" \
        '{user: $u, window_start: 0, reset_at: 0, used_sec: 0, budget_sec: $b, exhausted: false}' > "$qfile"
    fi
    chmod 0666 "$qfile" 2>/dev/null || true
  fi
}

get_remaining_pct() {
  local user="$1"
  local model="${2:-}"

  init_or_roll_window "$user"
  local qfile="$STATE_DIR/${user}.state.json"
  local exhausted used budget
  exhausted=$(jq -r '.exhausted // false' "$qfile" 2>/dev/null || echo false)
  if [[ "$exhausted" == "true" ]]; then
    echo 0
    return
  fi
  # Only the agy /usage check may mark an account low (it sets exhausted).
  # The local time-used counter is telemetry, never a switch decision, so an
  # account that is not marked exhausted always reads as available here.
  if [[ "${FM_AGY_LOCAL_ESTIMATE:-off}" != on ]]; then
    echo 100
    return
  fi
  used=$(jq -r '.used_sec // 0' "$qfile" 2>/dev/null || echo 0)
  budget=$(jq -r ".budget_sec // $DEFAULT_BUDGET_SEC" "$qfile" 2>/dev/null || echo "$DEFAULT_BUDGET_SEC")
  (( budget <= 0 )) && budget=$DEFAULT_BUDGET_SEC

  local pct=$(( 100 - (used * 100 / budget) ))
  (( pct < 0 )) && pct=0
  echo "$pct"
}

record_run() {
  local user="$1" dur="$2"
  init_or_roll_window "$user"
  local qfile="$STATE_DIR/${user}.state.json"
  local now
  now=$(now_epoch)

  local wstart reset_at used budget exhausted
  wstart=$(jq -r '.window_start // 0' "$qfile")
  reset_at=$(jq -r '.reset_at // 0' "$qfile")
  used=$(jq -r '.used_sec // 0' "$qfile")
  budget=$(jq -r ".budget_sec // $DEFAULT_BUDGET_SEC" "$qfile")
  exhausted=$(jq -r '.exhausted // false' "$qfile" 2>/dev/null || echo false)

  if (( wstart == 0 )); then
    wstart=$now
    reset_at=$(( now + WINDOW_SECONDS ))
  fi

  used=$(( used + dur ))

  # Quota exhaustion is marked by the caller (mark_account_exhausted) when a
  # failed run's log tail matches QUOTA_EXHAUSTION_RE; this accounting only
  # carries the existing flag and does not change budgets.

  local updated
  updated=$(jq \
    --arg u "$user" \
    --argjson ws "$wstart" \
    --argjson ra "$reset_at" \
    --argjson us "$used" \
    --argjson bg "$budget" \
    --argjson ex "$exhausted" \
    '{user: $u, window_start: $ws, reset_at: $ra, used_sec: $us, budget_sec: $bg, exhausted: $ex}
     + (if .quota then {quota: .quota} else {} end)' "$qfile" 2>/dev/null || true)
  if [[ -n "$updated" ]]; then
    printf '%s\n' "$updated" > "$qfile"
  else
    jq -n \
      --arg u "$user" \
      --argjson ws "$wstart" \
      --argjson ra "$reset_at" \
      --argjson us "$used" \
      --argjson bg "$budget" \
      --argjson ex "$exhausted" \
      '{user: $u, window_start: $ws, reset_at: $ra, used_sec: $us, budget_sec: $bg, exhausted: $ex}' > "$qfile"
  fi
  chmod 0666 "$qfile" 2>/dev/null || true
}

model_usage_group() {
  local model="${1:-}"
  case "${model,,}" in
    gpt*|claude*) printf '%s\n' "Claude and GPT models" ;;
    *) printf '%s\n' "Gemini Models" ;;
  esac
}

is_neon_model() {
  local model="${1:-}"
  case "${model,,}" in
    *neon*) return 0 ;;
    *) return 1 ;;
  esac
}

# Serialize every live agy query (models and /usage) across all homes and tasks
# on this host under one flock file, enforcing PACING_SECONDS between queries on
# different accounts (same-account back-to-back queries are not gapped). The
# pacing exists because one host and IP issuing the same command on several
# accounts at once risks Google banning those accounts.
run_live_agy_query() {
  local user="$1"
  shift
  local lockfile="$STATE_DIR/live-query.lock"
  local last_file="$STATE_DIR/last-live-query"
  if [[ ! -e "$lockfile" ]]; then
    : > "$lockfile" 2>/dev/null || true
    chmod 0666 "$lockfile" 2>/dev/null || true
  fi
  local rc=0
  (
    flock -x 9
    local last_ts="" last_user="" now elapsed wait_sec
    if [[ -f "$last_file" ]]; then
      IFS=$'\t' read -r last_ts last_user < "$last_file" || true
    fi
    if [[ -n "$last_user" && "$last_user" != "$user" && "$PACING_SECONDS" -gt 0 && "$last_ts" =~ ^[0-9]+$ ]]; then
      now=$(now_epoch)
      elapsed=$(( now - last_ts ))
      if (( elapsed >= 0 && elapsed < PACING_SECONDS )); then
        wait_sec=$(( PACING_SECONDS - elapsed ))
        sleep "$wait_sec"
      fi
    fi
    local qrc=0
    if command -v timeout >/dev/null 2>&1 && (( LIVE_TIMEOUT > 0 )); then
      timeout "$LIVE_TIMEOUT" sudo -n -u "$user" -H "$AGY_BIN" "$@" </dev/null 2>/dev/null || qrc=$?
    else
      sudo -n -u "$user" -H "$AGY_BIN" "$@" </dev/null 2>/dev/null || qrc=$?
    fi
    printf '%s\t%s\n' "$(now_epoch)" "$user" > "$last_file" 2>/dev/null || true
    chmod 0666 "$last_file" 2>/dev/null || true
    exit "$qrc"
  ) 9>>"$lockfile" || rc=$?
  return "$rc"
}

catalog_cache_file() {
  printf '%s/%s.models.json\n' "$STATE_DIR" "$1"
}

# Print "fresh", "stale", or "missing" for the named account's cached catalog.
# Strictly read-only.
catalog_cache_status() {
  local user="$1"
  local cfile
  cfile=$(catalog_cache_file "$user")
  [[ -f "$cfile" ]] || { echo "missing"; return 0; }
  local fetched count now age
  fetched=$(jq -r '.fetched_at // empty' "$cfile" 2>/dev/null || true)
  count=$(jq -r '(.models // []) | if type == "array" then length else 0 end' "$cfile" 2>/dev/null || echo 0)
  if [[ ! "$fetched" =~ ^[0-9]+$ ]] || [[ ! "$count" =~ ^[0-9]+$ ]] || (( count == 0 )); then
    echo "missing"
    return 0
  fi
  now=$(now_epoch)
  age=$(( now - fetched ))
  if (( age < MODELS_TTL )); then
    echo "fresh"
  else
    echo "stale"
  fi
}

catalog_has_model() {
  local user="$1" model="$2"
  local cfile
  cfile=$(catalog_cache_file "$user")
  [[ -f "$cfile" ]] || return 1
  jq -e --arg m "$model" '(.models // []) | index($m) != null' "$cfile" >/dev/null 2>&1
}

catalog_is_reserved() {
  local user="$1"
  local cfile
  cfile=$(catalog_cache_file "$user")
  [[ -f "$cfile" ]] || return 1
  jq -e '(.models // []) | any(ascii_downcase | contains("neon"))' "$cfile" >/dev/null 2>&1
}

parse_agy_models_output() {
  tr -d '\r' | awk -F'\t' '
  {
    if (NF >= 2) {
      id = $1
    } else {
      id = $0
    }
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", id)
    if (id ~ /^[A-Za-z0-9][A-Za-z0-9._-]+$/ && tolower(id) !~ /^(error|warning|notice|fetching)$/ && !seen[id]++) {
      print id
    }
  }'
}

write_catalog_cache() {
  local user="$1" now="$2"
  shift 2
  local cfile tmp json
  cfile=$(catalog_cache_file "$user")
  json=$(printf '%s\n' "$@" | jq -R . | jq -s --arg u "$user" --argjson ts "$now" '{user: $u, fetched_at: $ts, models: .}')
  tmp=$(mktemp "$STATE_DIR/.${user}.models.XXXXXX" 2>/dev/null || true)
  if [[ -n "$tmp" ]]; then
    printf '%s\n' "$json" > "$tmp"
    chmod 0666 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$cfile" 2>/dev/null || { cat "$tmp" > "$cfile"; rm -f "$tmp"; }
  else
    printf '%s\n' "$json" > "$cfile"
  fi
  chmod 0666 "$cfile" 2>/dev/null || true
}

# Refresh an account's model catalog only when absent or older than MODELS_TTL.
# Failed or unreachable fetches keep any previous cache and return non-zero
# (uncertainty, never support).
ensure_account_catalog() {
  local user="$1"
  local status
  status=$(catalog_cache_status "$user")
  if [[ "$status" == "fresh" ]]; then
    return 0
  fi

  local raw_models rc=0
  raw_models=$(run_live_agy_query "$user" models) || rc=$?
  local -a parsed=()
  if (( rc == 0 )) && [[ -n "$raw_models" ]]; then
    mapfile -t parsed < <(parse_agy_models_output <<<"$raw_models")
  fi
  if (( rc == 0 && ${#parsed[@]} > 0 )); then
    write_catalog_cache "$user" "$(now_epoch)" "${parsed[@]}"
    return 0
  fi

  echo "[fm-agy-pool] Notice: model catalog fetch for '$user' failed or returned no models (exit $rc); catalog is uncertain (keeping any prior cache)." >&2
  return 1
}

# Parse `agy -p /usage` output for a model group into:
#   min_pct|min_reset|weekly_pct|weekly_reset|five_hour_pct|five_hour_reset
parse_live_usage_output() {
  local group="${1:-Gemini Models}"
  tr -d '\r' | awk -F'\t' -v grp="$group" '
  BEGIN {
    min_pct = 999; min_reset = ""; count = 0
    wk_pct = ""; wk_reset = ""
    fh_pct = ""; fh_reset = ""
  }
  tolower($1) == tolower(grp) {
    label = tolower($2)
    pct = $3
    gsub(/[^0-9]/, "", pct)
    reset = $4
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", reset)
    if (pct != "") {
      pct_val = pct + 0
      count++
      if (pct_val < min_pct) {
        min_pct = pct_val
        min_reset = reset
      }
      if (label ~ /weekly/) {
        wk_pct = pct_val
        wk_reset = reset
      } else if (label ~ /five[[:space:]_-]*hour/) {
        fh_pct = pct_val
        fh_reset = reset
      }
    }
  }
  END {
    if (count > 0 && min_pct != 999) {
      printf "%s|%s|%s|%s|%s|%s\n", min_pct, min_reset, wk_pct, wk_reset, fh_pct, fh_reset
    } else {
      exit 1
    }
  }'
}

# Query live usage via `agy -p /usage` under the machine-wide lock and pacing.
# Prints "min_pct|min_reset|weekly_pct|weekly_reset|five_hour_pct|five_hour_reset".
# When verbose=true, prints matching raw group lines first.
query_live_usage_detail() {
  local user="$1"
  local group="${2:-Gemini Models}"
  local verbose="${3:-false}"
  local raw_output
  raw_output=$(run_live_agy_query "$user" -p /usage || true)
  [[ -z "$raw_output" ]] && return 1

  local parsed
  parsed=$(parse_live_usage_output "$group" <<<"$raw_output") || return 1

  if [[ "$verbose" == "true" ]]; then
    awk -F'\t' -v grp="$group" 'tolower($1) == tolower(grp)' <<<"$raw_output" || true
  fi
  printf '%s\n' "$parsed"
  return 0
}

reset_to_epoch() {
  local reset_str="${1:-}" rst_epoch=0
  if [[ -n "$reset_str" ]]; then
    rst_epoch=$(date -d "$reset_str" +%s 2>/dev/null || echo 0)
    [[ "$rst_epoch" =~ ^[0-9]+$ ]] || rst_epoch=0
  fi
  (( rst_epoch <= 0 )) && rst_epoch=$(( $(now_epoch) + WINDOW_SECONDS ))
  echo "$rst_epoch"
}

save_account_quota() {
  local user="$1" group="$2" min_pct="$3" min_reset="$4" wk_pct="$5" wk_reset="$6" fh_pct="$7" fh_reset="$8" rst_epoch="${9:-0}"
  init_or_roll_window "$user"
  local qfile="$STATE_DIR/${user}.state.json"
  local now min_val="null" wk_val="null" fh_val="null"
  now=$(now_epoch)
  [[ "$min_pct" =~ ^[0-9]+$ ]] && min_val="$min_pct"
  [[ "$wk_pct" =~ ^[0-9]+$ ]] && wk_val="$wk_pct"
  [[ "$fh_pct" =~ ^[0-9]+$ ]] && fh_val="$fh_pct"
  [[ "$rst_epoch" =~ ^[0-9]+$ ]] || rst_epoch=0

  local updated
  updated=$(jq \
    --arg g "$group" \
    --argjson mp "$min_val" \
    --arg mr "${min_reset:-}" \
    --argjson ra "$rst_epoch" \
    --argjson wp "$wk_val" \
    --arg wr "${wk_reset:-}" \
    --argjson fp "$fh_val" \
    --arg fr "${fh_reset:-}" \
    --argjson ca "$now" \
    '.quota = ((.quota // {}) + {($g): {min_pct: $mp, reset: $mr, reset_at: $ra, weekly_pct: $wp, weekly_reset: $wr, five_hour_pct: $fp, five_hour_reset: $fr, checked_at: $ca}})' \
    "$qfile" 2>/dev/null || true)
  if [[ -n "$updated" ]]; then
    printf '%s\n' "$updated" > "$qfile"
    chmod 0666 "$qfile" 2>/dev/null || true
  fi
}

# Read-only lookup of last recorded quota reading for (user, group).
# Prints "<pct>|<reset_at>|<exhausted>" where pct is integer or empty if unknown/expired.
get_last_quota_reading() {
  local user="$1" group="${2:-Gemini Models}"
  local qfile="$STATE_DIR/${user}.state.json"
  local now pct="" rst_at=0 exh=false
  now=$(now_epoch)

  if [[ -f "$qfile" ]]; then
    local qline
    qline=$(jq -r --arg g "$group" \
      '(.exhausted // false) as $ex | (.reset_at // 0) as $sra |
       (.quota[$g] // null) as $q |
       if $q != null then
         [($q.min_pct // ""), ($q.reset_at // $sra), $ex] | join("|")
       else
         ["", $sra, $ex] | join("|")
       end' "$qfile" 2>/dev/null || true)
    if [[ -n "$qline" ]]; then
      IFS='|' read -r pct rst_at exh <<<"$qline"
    fi
    [[ "$rst_at" =~ ^[0-9]+$ ]] || rst_at=0
    if (( rst_at > 0 && now >= rst_at )); then
      pct=""
      exh=false
      rst_at=0
    fi
  fi

  if [[ -z "$pct" && "$exh" != "true" && -f "$USAGE_LOG" ]]; then
    local last_entry l_pct l_rst l_rst_ep=0
    last_entry=$(jq -sc --arg u "$user" --arg g "$group" \
      '[.[] | select(.user == $u and (.event == "usage_check" or .event == "quota_end") and ((.group // "Gemini Models") == $g) and .gemini_min_pct != null)] | last' \
      "$USAGE_LOG" 2>/dev/null || true)
    if [[ -n "$last_entry" && "$last_entry" != "null" ]]; then
      l_pct=$(jq -r '.gemini_min_pct // empty' <<<"$last_entry" 2>/dev/null || true)
      l_rst=$(jq -r '.reset // empty' <<<"$last_entry" 2>/dev/null || true)
      if [[ "$l_pct" =~ ^[0-9]+$ ]]; then
        if [[ -n "$l_rst" ]]; then
          l_rst_ep=$(date -d "$l_rst" +%s 2>/dev/null || echo 0)
          [[ "$l_rst_ep" =~ ^[0-9]+$ ]] || l_rst_ep=0
        fi
        if (( l_rst_ep == 0 || now < l_rst_ep )); then
          pct="$l_pct"
          rst_at="$l_rst_ep"
        fi
      fi
    fi
  fi

  printf '%s|%s|%s\n' "$pct" "$rst_at" "$exh"
}

get_sticky_user() {
  local sfile="$STATE_DIR/last-active"
  [[ -f "$sfile" ]] || return 0
  head -n 1 "$sfile" 2>/dev/null | tr -d '[:space:]' || true
}

record_sticky_user() {
  local user="$1"
  [[ -n "$user" ]] || return 0
  local sfile="$STATE_DIR/last-active"
  printf '%s\n' "$user" > "$sfile" 2>/dev/null || true
  chmod 0666 "$sfile" 2>/dev/null || true
}

mark_account_exhausted() {
  local user="$1"
  local reset_epoch="${2:-0}"
  local qfile="$STATE_DIR/${user}.state.json"
  local now
  now=$(now_epoch)

  if (( reset_epoch <= 0 )); then
    reset_epoch=$(( now + WINDOW_SECONDS ))
  fi

  init_or_roll_window "$user"
  local used budget
  used=$(jq -r '.used_sec // 0' "$qfile" 2>/dev/null || echo 0)
  budget=$(jq -r ".budget_sec // $DEFAULT_BUDGET_SEC" "$qfile" 2>/dev/null || echo "$DEFAULT_BUDGET_SEC")

  local updated
  updated=$(jq \
    --arg u "$user" \
    --argjson ws "$now" \
    --argjson ra "$reset_epoch" \
    --argjson us "$used" \
    --argjson bg "$budget" \
    --argjson ex true \
    '{user: $u, window_start: $ws, reset_at: $ra, used_sec: $us, budget_sec: $bg, exhausted: $ex}
     + (if .quota then {quota: .quota} else {} end)' "$qfile" 2>/dev/null || true)
  if [[ -n "$updated" ]]; then
    printf '%s\n' "$updated" > "$qfile"
  else
    jq -n \
      --arg u "$user" \
      --argjson ws "$now" \
      --argjson ra "$reset_epoch" \
      --argjson us "$used" \
      --argjson bg "$budget" \
      --argjson ex true \
      '{user: $u, window_start: $ws, reset_at: $ra, used_sec: $us, budget_sec: $bg, exhausted: $ex}' > "$qfile"
  fi
  chmod 0666 "$qfile" 2>/dev/null || true
}

log_usage_event() {
  local event="$1" account="$2" group="$3" min_pct="$4" reset="$5" wk_pct="$6" wk_reset="$7" fh_pct="$8" fh_reset="$9" decision="${10:-}"
  [[ -d "$(dirname "$USAGE_LOG")" ]] || return 0

  local pct_val="null" wk_val="null" fh_val="null"
  [[ "$min_pct" =~ ^[0-9]+$ ]] && pct_val="$min_pct"
  [[ "$wk_pct" =~ ^[0-9]+$ ]] && wk_val="$wk_pct"
  [[ "$fh_pct" =~ ^[0-9]+$ ]] && fh_val="$fh_pct"

  if [[ -n "$decision" ]]; then
    jq -nc \
      --arg ts "$(date -Iseconds)" \
      --arg user "$account" \
      --arg model "${ROUTE_MODEL:-default}" \
      --arg task "${FM_TASK_ID:-}" \
      --arg ev "$event" \
      --arg grp "$group" \
      --arg dec "$decision" \
      --arg reset "${reset:-}" \
      --arg wr "${wk_reset:-}" \
      --arg fr "${fh_reset:-}" \
      --argjson pct "$pct_val" \
      --argjson wp "$wk_val" \
      --argjson fp "$fh_val" \
      '{ts: $ts, provider: "google-ai-pro-direct", user: $user, model: $model, task: $task, event: $ev, group: $grp, gemini_min_pct: $pct, reset: $reset, weekly_pct: $wp, weekly_reset: $wr, five_hour_pct: $fp, five_hour_reset: $fr, decision: $dec}' \
      >> "$USAGE_LOG" 2>/dev/null || true
  else
    jq -nc \
      --arg ts "$(date -Iseconds)" \
      --arg user "$account" \
      --arg model "${ROUTE_MODEL:-default}" \
      --arg task "${FM_TASK_ID:-}" \
      --arg ev "$event" \
      --arg grp "$group" \
      --arg reset "${reset:-}" \
      --arg wr "${wk_reset:-}" \
      --arg fr "${fh_reset:-}" \
      --argjson pct "$pct_val" \
      --argjson wp "$wk_val" \
      --argjson fp "$fh_val" \
      '{ts: $ts, provider: "google-ai-pro-direct", user: $user, model: $model, task: $task, event: $ev, group: $grp, gemini_min_pct: $pct, reset: $reset, weekly_pct: $wp, weekly_reset: $wr, five_hour_pct: $fp, five_hour_reset: $fr}' \
      >> "$USAGE_LOG" 2>/dev/null || true
  fi
}

log_usage_check() {
  local account="$1" min_pct="$2" reset="$3" decision="$4"
  local group="${5:-$(model_usage_group "${ROUTE_MODEL:-}")}"
  local wk_pct="${6:-}" wk_reset="${7:-}" fh_pct="${8:-}" fh_reset="${9:-}"
  log_usage_event "usage_check" "$account" "$group" "$min_pct" "$reset" "$wk_pct" "$wk_reset" "$fh_pct" "$fh_reset" "$decision"
}

# Take the start-of-task live reading for an account that was chosen without a
# selection-time /usage query (already-active reuse). Queries only that same
# account under the shared live-query lock, saves the reading, and logs it as
# the task's usage_check start. Prints the live percentage, or nothing when the
# read failed, so callers can report the reading they actually used.
record_start_reading() {
  local user="$1" group="${2:-Gemini Models}"
  local usage_detail live_pct="" live_reset="" wk_pct="" wk_reset="" fh_pct="" fh_reset=""
  if usage_detail=$(query_live_usage_detail "$user" "$group"); then
    IFS='|' read -r live_pct live_reset wk_pct wk_reset fh_pct fh_reset <<<"$usage_detail"
  fi
  if [[ -n "$live_pct" ]]; then
    local rst_epoch
    rst_epoch=$(reset_to_epoch "$live_reset")
    save_account_quota "$user" "$group" "$live_pct" "$live_reset" "$wk_pct" "$wk_reset" "$fh_pct" "$fh_reset" "$rst_epoch"
    log_usage_check "$user" "$live_pct" "$live_reset" "start" "$group" "$wk_pct" "$wk_reset" "$fh_pct" "$fh_reset"
    if (( live_pct <= MIN_REMAINING_PCT )); then
      mark_account_exhausted "$user" "$rst_epoch"
    fi
    printf '%s\n' "$live_pct"
    return 0
  fi
  log_usage_check "$user" "" "" "unknown" "$group" "" "" "" ""
  return 0
}

# Evaluate one candidate account for model support (refreshing stale/missing
# catalog once) and live /usage quota check (once). Sets _EVAL_PICKED and
# returns 0 when accepted; returns 2 if account should be deferred to reserved
# fallback; returns 1 otherwise.
# Uses caller-scoped vars: _EVAL_PICKED _EVAL_LIVE_PCT _CHECKED_MODELS _CHECKED_USAGE _DEFERRED_RESERVED.
evaluate_candidate_account() {
  local u="$1" model="$2" group="$3" allow_reserved="$4"
  _EVAL_PICKED=""
  _EVAL_LIVE_PCT=""
  local want_neon=0
  is_neon_model "$model" && want_neon=1

  case " $_CHECKED_USAGE " in *" $u "*) return 1 ;; esac

  id "$u" >/dev/null 2>&1 || return 1
  is_authenticated "$u" || return 1
  if is_user_exhausted "$u" "$model"; then
    return 1
  fi

  local last_info last_pct last_exh
  last_info=$(get_last_quota_reading "$u" "$group")
  IFS='|' read -r last_pct _ last_exh <<<"$last_info"
  if [[ "$last_exh" == "true" ]]; then
    return 1
  fi
  if [[ "$last_pct" =~ ^[0-9]+$ ]] && (( last_pct <= MIN_REMAINING_PCT )); then
    return 1
  fi

  # Check/refresh model catalog once per account in this selection
  local catalog_ok=1
  case " $_CHECKED_MODELS " in
    *" $u "*)
      [[ "$(catalog_cache_status "$u")" != "missing" ]] || catalog_ok=0
      ;;
    *)
      _CHECKED_MODELS="$_CHECKED_MODELS $u"
      if ! ensure_account_catalog "$u"; then
        catalog_ok=0
      fi
      ;;
  esac
  (( catalog_ok == 1 )) || return 1

  if (( want_neon == 0 && allow_reserved == 0 )) && catalog_is_reserved "$u"; then
    case " $_DEFERRED_RESERVED " in *" $u "*) ;; *) _DEFERRED_RESERVED="$_DEFERRED_RESERVED $u" ;; esac
    return 2
  fi

  if [[ -n "$model" && "$model" != "default" ]]; then
    catalog_has_model "$u" "$model" || return 1
  fi

  _CHECKED_USAGE="$_CHECKED_USAGE $u"
  local usage_detail live_pct live_reset wk_pct wk_reset fh_pct fh_reset
  if usage_detail=$(query_live_usage_detail "$u" "$group"); then
    IFS='|' read -r live_pct live_reset wk_pct wk_reset fh_pct fh_reset <<<"$usage_detail"
    if [[ -n "$live_pct" ]]; then
      local rst_epoch
      rst_epoch=$(reset_to_epoch "$live_reset")
      save_account_quota "$u" "$group" "$live_pct" "$live_reset" "$wk_pct" "$wk_reset" "$fh_pct" "$fh_reset" "$rst_epoch"
      if (( live_pct > MIN_REMAINING_PCT )); then
        log_usage_check "$u" "$live_pct" "$live_reset" "start" "$group" "$wk_pct" "$wk_reset" "$fh_pct" "$fh_reset"
        _EVAL_PICKED="$u"
        _EVAL_LIVE_PCT="$live_pct"
        return 0
      else
        log_usage_check "$u" "$live_pct" "$live_reset" "skip" "$group" "$wk_pct" "$wk_reset" "$fh_pct" "$fh_reset"
        mark_account_exhausted "$u" "$rst_epoch"
        echo "[fm-agy-pool] Account '$u' live quota is ${live_pct}% (floor=${MIN_REMAINING_PCT}%), exhausted until ${live_reset}; skipping to next account." >&2
        return 1
      fi
    fi
  fi

  log_usage_check "$u" "" "" "unknown" "$group" "" "" "" ""
  _EVAL_PICKED="$u"
  return 0
}

# Order accounts by: sticky first (when sticky_first=1), then known above-floor
# quota descending, then unknown quota in POOL_CONF order.
sort_candidates_by_quota() {
  local group="$1" sticky="$2"
  shift 2
  local -a rows=()
  local idx=0 u info pct key
  for u in "$@"; do
    idx=$(( idx + 1 ))
    info=$(get_last_quota_reading "$u" "$group")
    IFS='|' read -r pct _ _ <<<"$info"
    if [[ "$u" == "$sticky" ]]; then
      key=20000
    elif [[ "$pct" =~ ^[0-9]+$ ]]; then
      key=$(( 10000 + pct ))
    else
      key=5000
    fi
    rows+=("$(printf '%06d\t%06d\t%s\n' "$key" "$idx" "$u")")
  done
  if (( ${#rows[@]} > 0 )); then
    printf '%s\n' "${rows[@]}" | sort -t$'\t' -k1,1nr -k2,2n | cut -f3
  fi
}

pick_sticky_user() {
  local model="${1:-}"
  local explicit_user="${2:-${FM_AGY_USER:-}}"
  local group
  group=$(model_usage_group "$model")

  if [[ -n "$explicit_user" ]]; then
    if ! id "$explicit_user" >/dev/null 2>&1; then
      echo "[fm-agy-pool] ERROR: Requested user '$explicit_user' does not exist." >&2
      return 1
    fi
    if ! is_authenticated "$explicit_user"; then
      echo "[fm-agy-pool] ERROR: Requested user '$explicit_user' is not authenticated." >&2
      return 1
    fi
    if is_user_exhausted "$explicit_user" "$model"; then
      echo "[fm-agy-pool] ERROR: Requested user '$explicit_user' is marked exhausted for model '${model:-default}'." >&2
      return 1
    fi
    if [[ -n "$model" && "$model" != "default" ]]; then
      if ensure_account_catalog "$explicit_user"; then
        if ! catalog_has_model "$explicit_user" "$model"; then
          echo "[fm-agy-pool] ERROR: Requested user '$explicit_user' catalog does not list model '$model'." >&2
          return 1
        fi
      fi
    fi

    local usage_detail live_pct live_reset wk_pct wk_reset fh_pct fh_reset
    if usage_detail=$(query_live_usage_detail "$explicit_user" "$group"); then
      IFS='|' read -r live_pct live_reset wk_pct wk_reset fh_pct fh_reset <<<"$usage_detail"
      if [[ -n "$live_pct" ]]; then
        local rst_epoch
        rst_epoch=$(reset_to_epoch "$live_reset")
        save_account_quota "$explicit_user" "$group" "$live_pct" "$live_reset" "$wk_pct" "$wk_reset" "$fh_pct" "$fh_reset" "$rst_epoch"
        if (( live_pct <= MIN_REMAINING_PCT )); then
          log_usage_check "$explicit_user" "$live_pct" "$live_reset" "skip" "$group" "$wk_pct" "$wk_reset" "$fh_pct" "$fh_reset"
          mark_account_exhausted "$explicit_user" "$rst_epoch"
          echo "[fm-agy-pool] ERROR: Requested user '$explicit_user' quota is ${live_pct}% (floor=${MIN_REMAINING_PCT}%), exhausted until ${live_reset}." >&2
          return 1
        else
          log_usage_check "$explicit_user" "$live_pct" "$live_reset" "start" "$group" "$wk_pct" "$wk_reset" "$fh_pct" "$fh_reset"
        fi
      fi
    else
      log_usage_check "$explicit_user" "" "" "unknown" "$group" "" "" "" ""
    fi
    printf '%s|%s\n' "$explicit_user" "${live_pct:-}"
    return 0
  fi

  local sticky
  sticky=$(get_sticky_user)
  local want_neon=0
  is_neon_model "$model" && want_neon=1

  local _CHECKED_MODELS="" _CHECKED_USAGE="" _DEFERRED_RESERVED="" _EVAL_PICKED="" _EVAL_LIVE_PCT=""
  local -a tier1_pool=() known_reserved=()
  local u cstat
  for u in "${GPRO_USERS[@]}"; do
    cstat=$(catalog_cache_status "$u")
    if [[ "$cstat" == "fresh" ]] && [[ -n "$model" && "$model" != "default" ]]; then
      catalog_has_model "$u" "$model" || continue
    fi
    if (( want_neon == 0 )) && [[ "$cstat" != "missing" ]] && catalog_is_reserved "$u"; then
      known_reserved+=("$u")
    else
      tier1_pool+=("$u")
    fi
  done

  local -a ordered_t1=()
  if (( ${#tier1_pool[@]} > 0 )); then
    mapfile -t ordered_t1 < <(sort_candidates_by_quota "$group" "$sticky" "${tier1_pool[@]}")
  fi

  local rc
  for u in ${ordered_t1[@]+"${ordered_t1[@]}"}; do
    rc=0
    evaluate_candidate_account "$u" "$model" "$group" "$want_neon" || rc=$?
    if (( rc == 0 )) && [[ -n "$_EVAL_PICKED" ]]; then
      printf '%s|%s\n' "$_EVAL_PICKED" "$_EVAL_LIVE_PCT"
      return 0
    fi
  done

  if (( want_neon == 0 )); then
    local -a tier2_pool=()
    local d dup
    for d in ${known_reserved[@]+"${known_reserved[@]}"} $_DEFERRED_RESERVED; do
      [[ -n "$d" ]] || continue
      dup=0
      for u in ${tier2_pool[@]+"${tier2_pool[@]}"}; do
        [[ "$u" == "$d" ]] && { dup=1; break; }
      done
      (( dup == 0 )) && tier2_pool+=("$d")
    done
    local -a ordered_t2=()
    if (( ${#tier2_pool[@]} > 0 )); then
      mapfile -t ordered_t2 < <(sort_candidates_by_quota "$group" "$sticky" "${tier2_pool[@]}")
    fi
    for u in ${ordered_t2[@]+"${ordered_t2[@]}"}; do
      rc=0
      evaluate_candidate_account "$u" "$model" "$group" 1 || rc=$?
      if (( rc == 0 )) && [[ -n "$_EVAL_PICKED" ]]; then
        printf '%s|%s\n' "$_EVAL_PICKED" "$_EVAL_LIVE_PCT"
        return 0
      fi
    done
  fi

  return 1
}

# Check whether a pool account has a live agy process. Use per-account process checks only.
account_has_live_agy() {
  local user="$1"
  local pgrep_bin="${FM_AGY_PGREP:-pgrep}"
  "$pgrep_bin" -u "$user" -x agy >/dev/null 2>&1
}

find_active_pool_users() {
  local -a active=()
  for u in "${GPRO_USERS[@]}"; do
    if account_has_live_agy "$u"; then
      active+=("$u")
    fi
  done
  if (( ${#active[@]} > 0 )); then
    printf '%s\n' "${active[@]}"
  fi
}

cmd_usage() {
  local target="${1:-}"
  if [[ -z "$target" ]]; then
    echo "[fm-agy-pool] ERROR: --usage requires an account argument (e.g. --usage <account>)." >&2
    exit 1
  fi

  local -a active_users=()
  mapfile -t active_users < <(find_active_pool_users)
  local max_active="${FM_AGY_MAX_ACTIVE:-2}" target_active=0 act
  for act in ${active_users[@]+"${active_users[@]}"}; do
    [[ "$act" == "$target" ]] && target_active=1
  done
  if (( target_active == 0 && ${#active_users[@]} >= max_active )); then
    echo "[fm-agy-pool] ERROR: Another pool account ('${active_users[0]}') is currently active; refusing live usage check for '$target' (${#active_users[@]} pool accounts active, cap is $max_active (FM_AGY_MAX_ACTIVE))." >&2
    exit 75
  fi

  local group="Gemini Models"
  local usage_out detail live_pct live_reset wk_pct wk_reset fh_pct fh_reset
  if ! usage_out=$(query_live_usage_detail "$target" "$group" true); then
    echo "[fm-agy-pool] ERROR: Failed to query live usage for '$target'." >&2
    exit 1
  fi

  local line_count
  line_count=$(wc -l <<<"$usage_out")
  if (( line_count > 1 )); then
    head -n $(( line_count - 1 )) <<<"$usage_out"
  fi
  detail=$(tail -n 1 <<<"$usage_out")
  IFS='|' read -r live_pct live_reset wk_pct wk_reset fh_pct fh_reset <<<"$detail"
  printf '%s %s\n' "$live_pct" "$live_reset"

  local rst_epoch
  rst_epoch=$(reset_to_epoch "$live_reset")
  save_account_quota "$target" "$group" "$live_pct" "$live_reset" "$wk_pct" "$wk_reset" "$fh_pct" "$fh_reset" "$rst_epoch"
  log_usage_check "$target" "$live_pct" "$live_reset" "manual" "$group" "$wk_pct" "$wk_reset" "$fh_pct" "$fh_reset"
  if [[ -n "$live_pct" && "$live_pct" =~ ^[0-9]+$ && "$live_pct" -le "$MIN_REMAINING_PCT" ]]; then
    mark_account_exhausted "$target" "$rst_epoch"
  fi
  exit 0
}

cmd_status() {
  printf "%-11s %-14s %-16s %-22s %-26s %s\n" "ACCOUNT" "STATUS" "REMAINING" "RESET_AT" "CHECKED_AT" "CATALOG_TIER"
  for u in "${GPRO_USERS[@]}"; do
    local auth="PENDING_LOGIN"
    id "$u" >/dev/null 2>&1 || auth="MISSING_USER"
    [[ "$auth" == "PENDING_LOGIN" ]] && is_authenticated "$u" && auth="READY"

    local pct="unknown"
    local rst_str="unknown"
    local chk_ts="unknown"
    if [[ -f "$USAGE_LOG" ]]; then
      local last_entry
      last_entry=$(jq -s --arg u "$u" '[.[] | select(.user == $u and (.event == "usage_check" or .event == "quota_end"))] | last' "$USAGE_LOG" 2>/dev/null || true)
      if [[ -n "$last_entry" && "$last_entry" != "null" ]]; then
        local p r t
        p=$(jq -r '.gemini_min_pct // empty' <<<"$last_entry" 2>/dev/null || true)
        r=$(jq -r '.reset // empty' <<<"$last_entry" 2>/dev/null || true)
        t=$(jq -r '.ts // empty' <<<"$last_entry" 2>/dev/null || true)
        [[ -n "$r" ]] && rst_str="$r"
        [[ -n "$t" ]] && chk_ts="$t"
        if [[ -n "$p" && "$p" =~ ^[0-9]+$ ]]; then
          if (( p <= MIN_REMAINING_PCT )); then
            pct="${p}% (skip)"
          else
            pct="${p}%"
          fi
        fi
      fi
    fi

    local tier="unknown"
    local cstat
    cstat=$(catalog_cache_status "$u")
    if [[ "$cstat" != "missing" ]]; then
      if catalog_is_reserved "$u"; then
        tier="reserved (neon)"
      else
        tier="standard"
      fi
      [[ "$cstat" == "stale" ]] && tier="$tier,stale"
    fi

    printf "%-11s %-14s %-16s %-22s %-26s %s\n" \
      "$u" "$auth" "$pct" "$rst_str" "$chk_ts" "$tier"
  done
  exit 0
}

case "${1:-}" in
  --usage)
    cmd_usage "${2:-}"
    ;;
  --usage=*)
    cmd_usage "${1#*=}"
    ;;
  --status|--stats)
    cmd_status
    ;;
  --reset)
    target="${2:-}"
    if [[ -n "$target" ]]; then
      rm -f "$STATE_DIR/${target}.state.json"
      echo "[fm-agy-pool] Reset local window counter for '$target'."
    else
      rm -f "$STATE_DIR"/*.state.json
      echo "[fm-agy-pool] Reset local window counters for all accounts."
    fi
    exit 0
    ;;
esac

is_user_allowed_for_model() {
  local user="$1" model="${2:-}"
  if [[ -z "$model" || "$model" == "default" ]]; then
    return 0
  fi
  ensure_account_catalog "$user" || return 1
  catalog_has_model "$user" "$model"
}

is_user_exhausted() {
  local user="$1" model="${2:-}"
  local pct
  pct=$(get_remaining_pct "$user" "$model")
  (( pct <= MIN_REMAINING_PCT ))
}

# --check-account <account> [<model>]: the spawn-time gate for a named account
# (bin/fm-spawn.sh --account). Strictly read-only (no live query, no state
# writes): the account must be listed in POOL_CONF, exist, be signed in, pass
# the cached model catalog check (refuse when fresh catalog omits the model;
# allow with a notice when missing/stale), and not be marked exhausted. Prints
# the account on success; exits 1 with one reason otherwise.
cmd_check_account() {
  local user="${1:-}" model="${2:-${FM_AGY_POOL_MODEL:-}}" u listed=0
  if [[ -z "$user" ]]; then
    echo "[fm-agy-pool] ERROR: --check-account requires an account argument." >&2
    exit 1
  fi
  for u in "${GPRO_USERS[@]}"; do
    [[ "$u" == "$user" ]] && listed=1
  done
  if (( listed == 0 )); then
    echo "[fm-agy-pool] ERROR: '$user' is not an account in $POOL_CONF (pool accounts: ${GPRO_USERS[*]:-none})." >&2
    exit 1
  fi
  if ! id "$user" >/dev/null 2>&1; then
    echo "[fm-agy-pool] ERROR: pool account '$user' does not exist as a Linux user." >&2
    exit 1
  fi
  if ! is_authenticated "$user"; then
    echo "[fm-agy-pool] ERROR: pool account '$user' is not authenticated (no agy sign-in token)." >&2
    exit 1
  fi
  if [[ -n "$model" && "$model" != "default" ]]; then
    local cstat
    cstat=$(catalog_cache_status "$user")
    if [[ "$cstat" == "fresh" ]]; then
      if ! catalog_has_model "$user" "$model"; then
        echo "[fm-agy-pool] ERROR: pool account '$user' cached catalog does not list model '$model'." >&2
        exit 1
      fi
    else
      echo "[fm-agy-pool] Notice: model catalog for pool account '$user' is unknown ($cstat); allowing model '$model' unvalidated." >&2
    fi
  fi
  if account_marked_exhausted "$user"; then
    echo "[fm-agy-pool] ERROR: pool account '$user' is marked exhausted for model '${model:-default}'." >&2
    exit 1
  fi
  printf '%s\n' "$user"
  exit 0
}

# --check-model <model> [<account>]: read-only spawn-time model probe for
# bin/fm-spawn.sh on the pool launcher. Refuses only when the named account
# (or every pool account when unnamed) has a fresh catalog omitting <model>;
# allows with a notice when any relevant catalog is unknown (missing or stale).
cmd_check_model() {
  local model="${1:-}" user="${2:-}"
  if [[ -z "$model" || "$model" == "default" ]]; then
    exit 0
  fi
  if [[ -n "$user" ]]; then
    local cstat
    cstat=$(catalog_cache_status "$user")
    if [[ "$cstat" == "fresh" ]]; then
      if catalog_has_model "$user" "$model"; then
        exit 0
      fi
      echo "[fm-agy-pool] ERROR: agy model '$model' is not listed in pool account '$user' cached catalog; choose a listed id or omit --model." >&2
      exit 1
    fi
    echo "[fm-agy-pool] Notice: model catalog for pool account '$user' is unknown ($cstat); allowing '--model $model' unvalidated." >&2
    exit 0
  fi

  if (( ${#GPRO_USERS[@]} == 0 )); then
    echo "[fm-agy-pool] Notice: no pool accounts configured; allowing '--model $model' unvalidated." >&2
    exit 0
  fi

  local u cstat found_fresh=0 has_unknown=0
  for u in "${GPRO_USERS[@]}"; do
    cstat=$(catalog_cache_status "$u")
    if [[ "$cstat" == "fresh" ]]; then
      if catalog_has_model "$u" "$model"; then
        found_fresh=1
        break
      fi
    else
      has_unknown=1
    fi
  done
  if (( found_fresh == 1 )); then
    exit 0
  fi
  if (( has_unknown == 1 )); then
    echo "[fm-agy-pool] Notice: cached model catalog is unknown for one or more pool accounts; allowing '--model $model' unvalidated." >&2
    exit 0
  fi
  echo "[fm-agy-pool] ERROR: agy model '$model' is not listed in any pool account's cached catalog; choose a listed id or omit --model." >&2
  exit 1
}

# Read-only: is the account's recorded exhaustion window still open. Reads the
# state file without creating or rolling it (init_or_roll_window writes).
account_marked_exhausted() {
  local qfile="$STATE_DIR/${1}.state.json" exhausted reset_at
  [[ -f "$qfile" ]] || return 1
  exhausted=$(jq -r '.exhausted // false' "$qfile" 2>/dev/null || echo false)
  [[ "$exhausted" == true ]] || return 1
  reset_at=$(jq -r '.reset_at // 0' "$qfile" 2>/dev/null || echo 0)
  (( reset_at > 0 && $(now_epoch) >= reset_at )) && return 1
  return 0
}

# --check-capacity [<account>]: the spawn-time capacity gate. Read-only (a
# process check per account, no state writes, no network). Exits 75 with the
# reason when FM_AGY_MAX_ACTIVE pool accounts already run and the named account
# (if any) is not one of them; a named account that is already active fits.
cmd_check_capacity() {
  local target="${1:-}" max="${FM_AGY_MAX_ACTIVE:-2}" act
  local -a active=()
  mapfile -t active < <(find_active_pool_users)
  for act in ${active[@]+"${active[@]}"}; do
    [[ -n "$target" && "$act" == "$target" ]] && exit 0
  done
  if (( ${#active[@]} >= max )); then
    echo "[fm-agy-pool] ERROR: ${#active[@]} pool accounts already active (${active[*]}); cap is $max (FM_AGY_MAX_ACTIVE). Retry once a pool worker finishes or exits." >&2
    exit 75
  fi
  exit 0
}
if [[ "${1:-}" == --check-account ]]; then
  cmd_check_account "${2:-}" "${3:-}"
fi
if [[ "${1:-}" == --check-model ]]; then
  cmd_check_model "${2:-}" "${3:-}"
fi
if [[ "${1:-}" == --check-capacity ]]; then
  cmd_check_capacity "${2:-}"
fi

# Parse --user / --account (strip before passing to agy) and inspect --model / -m (keep for agy)
EXPLICIT_USER="${FM_AGY_USER:-}"
REQ_MODEL=""
REQ_CONVERSATION=""
AGY_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user|--account)
      EXPLICIT_USER="${2:-}"
      shift 2
      ;;
    --user=*|--account=*)
      EXPLICIT_USER="${1#*=}"
      shift
      ;;
    --model|-m)
      REQ_MODEL="${2:-}"
      AGY_ARGS+=("$1" "${2:-}")
      shift 2
      ;;
    --model=*|-m=*)
      REQ_MODEL="${1#*=}"
      AGY_ARGS+=("$1")
      shift
      ;;
    --conversation)
      REQ_CONVERSATION="${2:-}"
      AGY_ARGS+=("$1" "${2:-}")
      shift 2
      ;;
    --conversation=*)
      REQ_CONVERSATION="${1#*=}"
      AGY_ARGS+=("$1")
      shift
      ;;
    *)
      AGY_ARGS+=("$1")
      shift
      ;;
  esac
done

# A caller that cannot pass --model (for example `agy models`, which rejects the
# flag) names the model it is asking about through FM_AGY_POOL_MODEL so the
# listing comes from an account that actually carries that model.
ROUTE_MODEL="${REQ_MODEL:-${FM_AGY_POOL_MODEL:-}}"

# Claude models never route through Antigravity; they run on the native Claude
# CLI or the LiteLLM gateway instead.
case "${ROUTE_MODEL,,}" in
  claude*)
    echo "[fm-agy-pool] ERROR: model '$ROUTE_MODEL' is a Claude model; Claude does not run through Antigravity. Use the claude or pi harness." >&2
    exit 2
    ;;
esac

# Conversation affinity. agy keeps a conversation, and the server-side cache
# behind it, on the account that created it; a resumed call routed to another
# account silently starts a cold conversation. The owner comes from the small
# conversation->account record this wrapper keeps, else from the conversation
# files under each pool account's agy directory.
AGY_HOME_BASE="${FM_AGY_HOME_BASE:-/home}"
CONV_RECORD="$STATE_DIR/conversations.tsv"
CONVERSATION_PINNED=0

conversation_owner() {
  local id="$1" u owner=""
  [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  if [[ -f "$CONV_RECORD" ]]; then
    owner=$(awk -F'\t' -v id="$id" '$1 == id {u = $2} END {if (u != "") print u}' "$CONV_RECORD")
    if [[ -n "$owner" ]]; then
      for u in "${GPRO_USERS[@]}"; do
        if [[ "$u" == "$owner" ]] && is_user_allowed_for_model "$owner" "$ROUTE_MODEL"; then
          printf '%s\n' "$owner"
          return 0
        fi
      done
    fi
  fi
  for u in "${GPRO_USERS[@]}"; do
    if [[ -n "$(sudo -n -u "$u" find "$AGY_HOME_BASE/$u/.gemini/antigravity-cli/conversations" -maxdepth 1 -name "*${id}*" -print -quit 2>/dev/null)" ]]; then
      if is_user_allowed_for_model "$u" "$ROUTE_MODEL"; then
        printf '%s\n' "$u"
        return 0
      fi
    fi
  done
  return 1
}

record_conversation_owner() {
  local user="$1" log_tail="$2" id
  id=$(grep -Eo '"conversation_id"[[:space:]]*:[[:space:]]*"[A-Za-z0-9._-]+"' <<<"$log_tail" | tail -n 1 | sed -E 's/.*"([^"]+)"$/\1/' || true)
  [[ -n "$id" ]] || return 0
  grep -qF "$id"$'\t'"$user" "$CONV_RECORD" 2>/dev/null && return 0
  printf '%s\t%s\n' "$id" "$user" >> "$CONV_RECORD" 2>/dev/null || true
  chmod 0644 "$CONV_RECORD" 2>/dev/null || true
}

if [[ -n "$REQ_CONVERSATION" && "${AGY_ARGS[0]:-}" != models ]]; then
  if conv_owner=$(conversation_owner "$REQ_CONVERSATION"); then
    if [[ -n "$EXPLICIT_USER" && "$EXPLICIT_USER" != "$conv_owner" ]]; then
      echo "[fm-agy-pool] Conversation '$REQ_CONVERSATION' belongs to '$conv_owner'; overriding requested account '$EXPLICIT_USER'." >&2
    fi
    EXPLICIT_USER="$conv_owner"
    CONVERSATION_PINNED=1
  fi
fi

# Parse reset time from agy log tail:
# - "Resets in 2h48m0s" / "reset in 45m10s" -> now + duration
# - "Resets at <timestamp>" / "reset at <timestamp>" -> date -d epoch
# Prints epoch > now, or 0 if unparsable.
parse_reset_epoch_from_log() {
  local text="${1:-}" now rst_epoch=0
  now=$(now_epoch)

  local dur_line
  dur_line=$(grep -Eio 'resets?[[:space:]]+in[[:space:]]+[0-9]+[[:space:]]*[dhms]([[:space:]]*[0-9]+[[:space:]]*[dhms])*' <<<"$text" | tail -n 1 || true)
  if [[ -n "$dur_line" ]]; then
    local total_sec
    total_sec=$(awk '
      {
        s = tolower($0)
        sub(/^.*resets?[[:space:]]+in[[:space:]]+/, "", s)
        total = 0
        while (match(s, /^[[:space:]]*[0-9]+[[:space:]]*[dhms]/)) {
          tok = substr(s, RSTART, RLENGTH)
          unit = substr(tok, length(tok), 1)
          val = tok
          gsub(/[^0-9]/, "", val)
          val = val + 0
          if (unit == "d") total += val * 86400
          else if (unit == "h") total += val * 3600
          else if (unit == "m") total += val * 60
          else if (unit == "s") total += val
          s = substr(s, RSTART + RLENGTH)
        }
        print total
      }' <<<"$dur_line")
    if [[ "$total_sec" =~ ^[0-9]+$ ]] && (( total_sec > 0 )); then
      echo $(( now + total_sec ))
      return 0
    fi
  fi

  local ts_line ts_val
  ts_line=$(grep -Eio '(resets?[[:space:]]+at|until)[[:space:]]+[^[:space:]]+' <<<"$text" | tail -n 1 || true)
  if [[ -n "$ts_line" ]]; then
    ts_val=$(sed -E 's/^(resets?[[:space:]]+at|until)[[:space:]]+//I; s/[.,;]+$//' <<<"$ts_line")
    rst_epoch=$(date -d "$ts_val" +%s 2>/dev/null || echo 0)
    if [[ "$rst_epoch" =~ ^[0-9]+$ ]] && (( rst_epoch > now )); then
      echo "$rst_epoch"
      return 0
    fi
  fi

  echo 0
}

# Active account cap: at most FM_AGY_MAX_ACTIVE pool accounts run at once
# (default 2, so one account can build on Flash while another reviews or
# fixes on Neon/Hydrogen). Per-account process check only, no network calls.
MAX_ACTIVE="${FM_AGY_MAX_ACTIVE:-2}"

select_pool_user() {
  local active_users=() active_user picked="" picked_pct=""
  mapfile -t active_users < <(find_active_pool_users)
  if (( ${#active_users[@]} > 0 )); then
    if [[ -n "$EXPLICIT_USER" ]]; then
      for active_user in "${active_users[@]}"; do
        [[ "$EXPLICIT_USER" == "$active_user" ]] || continue
        is_user_allowed_for_model "$active_user" "$ROUTE_MODEL" || continue
        is_user_exhausted "$active_user" "$ROUTE_MODEL" && continue
        picked="$active_user"
        break
      done
    elif (( ${#active_users[@]} >= MAX_ACTIVE )); then
      local group sticky want_neon=0
      group=$(model_usage_group "$ROUTE_MODEL")
      sticky=$(get_sticky_user)
      is_neon_model "$ROUTE_MODEL" && want_neon=1
      local -a fit_normal=() fit_reserved=() ordered=()
      for active_user in "${active_users[@]}"; do
        is_user_allowed_for_model "$active_user" "$ROUTE_MODEL" || continue
        is_user_exhausted "$active_user" "$ROUTE_MODEL" && continue
        if (( want_neon == 0 )) && catalog_is_reserved "$active_user"; then
          fit_reserved+=("$active_user")
        else
          fit_normal+=("$active_user")
        fi
      done
      if (( ${#fit_normal[@]} > 0 )); then
        mapfile -t ordered < <(sort_candidates_by_quota "$group" "$sticky" "${fit_normal[@]}")
        picked="${ordered[0]:-}"
      elif (( ${#fit_reserved[@]} > 0 )); then
        mapfile -t ordered < <(sort_candidates_by_quota "$group" "$sticky" "${fit_reserved[@]}")
        picked="${ordered[0]:-}"
      fi
    fi
  fi
  if [[ -z "$picked" ]]; then
    if (( ${#active_users[@]} >= MAX_ACTIVE )); then
      echo "[fm-agy-pool] ERROR: ${#active_users[@]} pool accounts already active (${active_users[*]}), none fit model '${ROUTE_MODEL:-default}'${EXPLICIT_USER:+ / account $EXPLICIT_USER}; cap is $MAX_ACTIVE (FM_AGY_MAX_ACTIVE)." >&2
      return 75
    fi
    local selection
    selection=$(pick_sticky_user "$ROUTE_MODEL" "$EXPLICIT_USER" || true)
    if [[ -n "$selection" ]]; then
      picked="${selection%%|*}"
      picked_pct="${selection#*|}"
    fi
  else
    picked_pct=$(record_start_reading "$picked" "$(model_usage_group "$ROUTE_MODEL")")
  fi
  if [[ -z "$picked" ]]; then
    return 1
  fi
  printf '%s|%s\n' "$picked" "$picked_pct"
}

TASK_LABEL="${FM_TASK_ID:-${PWD##*/}}"
RUN_LOG_EPHEMERAL=1
if [[ -n "${FM_AGY_RUN_LOG:-}" ]]; then
  RUN_LOG="$FM_AGY_RUN_LOG"
  RUN_LOG_EPHEMERAL=0
  mkdir -p "$(dirname "$RUN_LOG")" 2>/dev/null || true
  : >> "$RUN_LOG"
  chmod 0644 "$RUN_LOG" 2>/dev/null || true
else
  RUN_LOG=$(mktemp /tmp/fm-agy-run.XXXXXX)
  chmod 0644 "$RUN_LOG" 2>/dev/null || true
fi
SCHEMA_COPIES=()
cleanup_pool_tmp() {
  if [[ "$RUN_LOG_EPHEMERAL" -eq 1 ]]; then
    rm -f "$RUN_LOG"
  fi
  if (( ${#SCHEMA_COPIES[@]} > 0 )); then
    rm -f "${SCHEMA_COPIES[@]}"
  fi
  if [[ -n "${STDIN_BUF:-}" ]]; then
    rm -f "$STDIN_BUF"
  fi
}
trap cleanup_pool_tmp EXIT
umask 0002

# A caller such as no-mistakes writes its --json-schema file private to the
# operator (mode 600), which the pool account cannot read. Hand the pool a
# readable copy instead; the schema holds no secrets.
_fix_args=()
_want_schema=0
for _a in "${AGY_ARGS[@]}"; do
  if [[ $_want_schema -eq 1 && -f "$_a" ]]; then
    _copy=$(mktemp /tmp/fm-agy-schema.XXXXXX)
    cat "$_a" > "$_copy" && chmod 0644 "$_copy"
    SCHEMA_COPIES+=("$_copy"); _a="$_copy"
  elif [[ "$_a" == --json-schema=* && -f "${_a#--json-schema=}" ]]; then
    _copy=$(mktemp /tmp/fm-agy-schema.XXXXXX)
    cat "${_a#--json-schema=}" > "$_copy" && chmod 0644 "$_copy"
    SCHEMA_COPIES+=("$_copy"); _a="--json-schema=$_copy"
  fi
  _want_schema=0
  [[ "$_a" == --json-schema ]] && _want_schema=1
  _fix_args+=("$_a")
done
AGY_ARGS=("${_fix_args[@]}")

# sudo's env_reset drops the worker environment, so forward what a firstmate
# worker needs: PATH (node-based tools such as tasks-axi live under the
# operator's nvm tree), the task temp and identity variables fm-spawn exports,
# trace context, and the terminal/multiplexer identity. HOME stays the pool
# account's own so agy finds that account's sign-in.
FORWARD_ENV=()
while IFS= read -r name; do
  case "$name" in
    PATH|TERM|COLORTERM|LANG|LC_*|TMPDIR|TMP|TEMP|GOTMPDIR|COMPACT_ADVISER_DISABLE|LAVISH_AXI_HOST|TRACEPARENT|FM_*|HERDR_*|TMUX|TMUX_PANE)
      FORWARD_ENV+=("$name=${!name}") ;;
  esac
done < <(compgen -e)

# fm-spawn creates the per-task temp root private to the operator; grant the
# shared agents group access so the pool account can use it. Only fm-owned
# /tmp/fm-* directories owned by this user are touched.
grant_task_tmp() {
  local dir=$1 root
  [[ -n "$dir" ]] || return 0
  root=$dir
  while [[ "$root" == /tmp/fm-*/* ]]; do root=${root%/*}; done
  [[ "$root" == /tmp/fm-* && -d "$root" && -O "$root" ]] || return 0
  setfacl -R -m g:agents:rwX -m d:g:agents:rwX "$root" 2>/dev/null || true
}
grant_task_tmp "${GOTMPDIR:-}"
grant_task_tmp "${TMPDIR:-}"

# A pool worker writes its task's report and scratch files under data/<task>
# (a scout's report.md most of all), which the operator created private. Grant
# only the selected pool account an ACL on that one directory, access plus
# default, so files it creates there stay readable and writable for both sides.
grant_task_data() {
  local user=$1 task=${FM_TASK_ID:-} home
  [[ -n "$task" && "$task" =~ ^[A-Za-z0-9._-]+$ ]] || return 0
  home=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
  [[ -d "$home/data/$task" && ! -L "$home/data/$task" && -O "$home/data/$task" ]] || return 0
  setfacl -R -m "u:${user}:rwX" -m "d:u:${user}:rwX" "$home/data/$task" 2>/dev/null || true
}

# fm-spawn pre-registers the worktree in the operator's agy trust store; mirror
# exactly that entry into the selected pool account's store so its launch does
# not stop on the folder-trust dialog. Nothing is mirrored for a folder the
# operator has not trusted.
mirror_trust() {
  local own="$HOME/.gemini/antigravity-cli/settings.json" logical=$PWD resolved
  resolved=$(pwd -P)
  [[ -f "$own" ]] || return 0
  jq -e --arg a "$logical" --arg b "$resolved" '(.trustedWorkspaces // []) | index($a) or index($b)' "$own" >/dev/null 2>&1 || return 0
  sudo -n -H -u "$SELECTED_USER" /usr/bin/env A="$logical" B="$resolved" bash -c '
    f="$HOME/.gemini/antigravity-cli/settings.json"
    mkdir -p "${f%/*}"; [ -s "$f" ] || echo "{}" > "$f"
    t=$(mktemp "${f}.XXXXXX") &&
    jq --arg a "$A" --arg b "$B" ".trustedWorkspaces = (((.trustedWorkspaces // []) + [\$a, \$b]) | unique)" "$f" > "$t" &&
    mv "$t" "$f"' 2>/dev/null || true
}

# Firstmate's scripts write task records through mktemp+mv, which leaves each
# record mode 0600 and owned by its writer. Run by the worker as the pool
# account, they lock the operator's firstmate out of its own records; run by
# the operator (fm-send's inbox messages), they lock the worker out of its
# steering. For a firstmate task worker, two helpers restore group access for
# the shared agents group while the wrapper lives and once more after it exits,
# each as the only identity allowed to chmod its own files: one as the pool
# account over that account's files under the task's state and data paths, one
# as the operator over only this task's own state records and inbox.
keep_group_access() {
  local home task
  task=${FM_TASK_ID:-}
  [[ -n "$task" ]] || return 0
  home=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
  [[ -d "$home/state" ]] || return 0
  local dirs=("$home/state")
  [[ -d "$home/data/$task" ]] && dirs+=("$home/data/$task")
  # A named default entry for the operator makes the restored access effective
  # even in an operator session that predates its agents-group membership.
  local d me
  me=$(id -un)
  for d in "${dirs[@]}"; do
    [[ -O "$d" ]] && setfacl -m "u:$me:rwX" -m "d:u:$me:rwX" "$d" 2>/dev/null
  done
  # A ship can be handed from the pool worker to a worker running as the
  # operator in the same task copy, so once the pool worker is gone its files
  # in that copy and in the repository's shared git directory are handed back
  # too: group-writable, plus a named operator entry for an operator session
  # that predates its agents-group membership.
  local top common
  top=$(git rev-parse --show-toplevel 2>/dev/null || true)
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  # shellcheck disable=SC2016  # expanded by the pool account's bash, not here
  setsid sudo -n -H -u "$SELECTED_USER" /usr/bin/env WATCH_PID=$$ OP="$me" TOP="$top" COMMON="$common" bash -c '
    me=$(id -un)
    sweep() { find "$@" -maxdepth 2 -user "$me" ! -perm -g=rw -exec chmod g+rwX {} + 2>/dev/null; }
    while [ -d "/proc/$WATCH_PID" ]; do sweep "$@"; sleep 0.5; done
    sweep "$@"
    for d in "$TOP" "$COMMON"; do
      [ -n "$d" ] && [ -d "$d" ] || continue
      find "$d" -user "$me" ! -perm -g=rw -exec chmod g+rwX {} + 2>/dev/null
      find "$d" -user "$me" -type f -exec setfacl -m "u:$OP:rwX" {} + 2>/dev/null
      find "$d" -user "$me" -type d -exec setfacl -m "u:$OP:rwx" -m "d:u:$OP:rwx" {} + 2>/dev/null
    done' _ "${dirs[@]}" </dev/null >/dev/null 2>&1 &
  # The doorbell rings right after fm-send writes a message, so this side
  # sweeps at the same short interval; an unread message is rung again anyway.
  # shellcheck disable=SC2016  # expanded by the helper's bash, not here
  setsid /usr/bin/env WATCH_PID=$$ ME="$me" STATE_DIR="$home/state" TASK="$task" bash -c '
    sweep() {
      find "$STATE_DIR" -maxdepth 1 \( -name "$TASK.meta" -o -name "$TASK.status" \) \
        -user "$ME" ! -perm -g=rw -exec chmod g+rw {} + 2>/dev/null
      [ -d "$STATE_DIR/$TASK.inbox" ] &&
        find "$STATE_DIR/$TASK.inbox" -maxdepth 2 -user "$ME" ! -perm -g=rw -exec chmod g+rwX {} + 2>/dev/null
    }
    while [ -d "/proc/$WATCH_PID" ]; do sweep; sleep 0.5; done
    sweep' </dev/null >/dev/null 2>&1 &
}

# Interactive worker sessions deliver steering messages mid-turn: agy's default
# "Queue" mode holds a typed message until the whole turn ends (observed: over
# an hour on a long build), while "send-immediately" joins the running turn and
# the agent reads it after its current step. Applied per launch through
# --settings (never saved to the account) unless the caller already passes
# --settings; FM_AGY_QUEUED_MESSAGES=queue keeps agy's default.
# The same per-launch settings also switch off agy's end-of-turn feedback survey
# ("How's the CLI experience so far?"), which otherwise replaces the idle input
# row and makes firstmate's exit and steering checks read the screen as unknown.
IS_INTERACTIVE=0
for _a in "${AGY_ARGS[@]}"; do
  case "$_a" in
    --prompt-interactive|--prompt-interactive=*|-i) IS_INTERACTIVE=1 ;;
  esac
done

# Direct-PR and local-only ship workers push and open PRs themselves. The pool
# account's git credential helper already reads the operator's gh login
# (bin/fm-agy-pool-setup.sh git-auth); for exactly those interactive worker
# launches hand gh the same read-only config dir. Scouts, no-mistakes builders,
# and no-mistakes reviewer/fixer calls (nm-agy) never receive it.
forward_gh_config() {
  local meta kind mode dir
  (( IS_INTERACTIVE )) || return 0
  [[ -n "${FM_TASK_ID:-}" && "${FM_TASK_ID}" =~ ^[A-Za-z0-9._-]+$ ]] || return 0
  meta="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}/state/${FM_TASK_ID}.meta"
  [[ -f "$meta" ]] || return 0
  kind=$(sed -n 's/^kind=//p' "$meta" | head -n 1)
  mode=$(sed -n 's/^mode=//p' "$meta" | head -n 1)
  [[ "$kind" == ship && ( "$mode" == direct-PR || "$mode" == local-only ) ]] || return 0
  dir="${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}"
  [[ -d "$dir" ]] && FORWARD_ENV+=("GH_CONFIG_DIR=$dir")
  return 0
}
forward_gh_config

add_queued_messages_setting() {
  local mode="${FM_AGY_QUEUED_MESSAGES:-send-immediately}" a json
  for a in "${AGY_ARGS[@]}"; do
    case "$a" in
      --settings|--settings=*) return 0 ;;
    esac
  done
  (( IS_INTERACTIVE )) || return 0
  json='"showFeedbackSurvey":false'
  [[ "$mode" == queue ]] || json="\"queuedMessages\":\"$mode\",$json"
  AGY_ARGS+=(--settings "{$json}")
}
add_queued_messages_setting

QUOTA_EXHAUSTION_RE='^[[:space:]]*(\[fm-agy-pool\][[:space:]]*ERROR:.*|antigravity exited .*error=.*|antigravity reported error:.*|error:.*)?[[:space:]]*(All eligible accounts|No eligible account|Individual quota reached|RESOURCE_EXHAUSTED|429([[:space:]]|$)|rate[ -]?limit exceeded|quota exceeded|out of quota)'
RETRIED_AFTER_QUOTA=0
STDIN_BUF=""
if [[ ! -t 0 ]]; then
  for a in "${AGY_ARGS[@]}"; do
    if [[ "$a" == --input-format || "$a" == --input-format=* ]]; then
      STDIN_BUF=$(mktemp)
      cat > "$STDIN_BUF"
      break
    fi
  done
fi
MAX_ATTEMPTS=$(( ${#GPRO_USERS[@]} + 2 ))
ATTEMPT=0
EXIT_CODE=0
KEPT_ACCESS_USERS=""

while (( ATTEMPT < MAX_ATTEMPTS )); do
  ATTEMPT=$(( ATTEMPT + 1 ))
  SELECTED_USER=""
  SELECTED_PCT=""
  select_rc=0
  selection=$(select_pool_user) || select_rc=$?
  if [[ -n "$selection" ]]; then
    SELECTED_USER="${selection%%|*}"
    SELECTED_PCT="${selection#*|}"
  fi
  if [[ -z "$SELECTED_USER" ]]; then
    if [[ $CONVERSATION_PINNED -eq 1 ]]; then
      echo "[fm-agy-pool] ERROR: account '$EXPLICIT_USER' owns conversation '$REQ_CONVERSATION' but cannot take the call now; not running it on another account, which would drop the conversation and its cache." >&2
      exit 75
    fi
    if [[ $RETRIED_AFTER_QUOTA -eq 1 ]]; then
      echo "[fm-agy-pool] ERROR: All eligible accounts for model '${ROUTE_MODEL:-default}' are exhausted." >&2
      exit 75
    fi
    if [[ $select_rc -ne 75 ]]; then
      echo "[fm-agy-pool] ERROR: No eligible account in $POOL_CONF for model '${ROUTE_MODEL:-default}' above ${MIN_REMAINING_PCT}% remaining quota." >&2
    fi
    exit 75
  fi

  PCT_LABEL="unknown"
  [[ -n "$SELECTED_PCT" ]] && PCT_LABEL="${SELECTED_PCT}%"
  START_TS=$(now_epoch)
  if [[ "$RUN_LOG_EPHEMERAL" -eq 1 ]]; then
    : > "$RUN_LOG"
  fi
  chmod 0644 "$RUN_LOG" 2>/dev/null || true
  RUN_LOG_OFFSET=$(wc -c < "$RUN_LOG" 2>/dev/null || echo 0)

  echo "[fm-agy-pool] Routing model '${ROUTE_MODEL:-default}' to '$SELECTED_USER' (${PCT_LABEL} remaining, floor=${MIN_REMAINING_PCT}%)..." >&2

  if [[ "${AGY_ARGS[0]:-}" != models ]]; then
    record_sticky_user "$SELECTED_USER"
    mirror_trust
    grant_task_data "$SELECTED_USER"
    case " $KEPT_ACCESS_USERS " in
      *" $SELECTED_USER "*) ;;
      *)
        keep_group_access
        KEPT_ACCESS_USERS="${KEPT_ACCESS_USERS} ${SELECTED_USER}"
        ;;
    esac
  fi

  RUN_CMD=(sudo -H -u "$SELECTED_USER"
    /usr/bin/env -u GEMINI_API_KEY -u GOOGLE_API_KEY -u ANTHROPIC_BASE_URL -u OPENAI_BASE_URL -u LITELLM_BASE_URL
    "${FORWARD_ENV[@]}"
    "$AGY_BIN" "${AGY_ARGS[@]}")

  set +e
  if [[ -t 0 && -t 1 ]]; then
    # Interactive worker pane: agy's TUI needs a real terminal on stdout, and a
    # pipe through tee leaves the pane blank. script(1) keeps the terminal and
    # still records the session for quota-hit detection.
    if [[ "$RUN_LOG_EPHEMERAL" -eq 0 ]]; then
      script -q -f -a -e -c "$(printf '%q ' "${RUN_CMD[@]}")" "$RUN_LOG"
    else
      script -q -f -e -c "$(printf '%q ' "${RUN_CMD[@]}")" "$RUN_LOG"
    fi
    EXIT_CODE=$?
  else
    if [[ -n "$STDIN_BUF" ]]; then
      exec 3<"$STDIN_BUF"
    else
      exec 3<&0
    fi
    if [[ "$RUN_LOG_EPHEMERAL" -eq 0 ]]; then
      "${RUN_CMD[@]}" 2>&1 <&3 | tee -a "$RUN_LOG"
    else
      "${RUN_CMD[@]}" 2>&1 <&3 | tee "$RUN_LOG"
    fi
    EXIT_CODE=${PIPESTATUS[0]}
    exec 3<&-
  fi
  set -e

  DURATION=$(( $(now_epoch) - START_TS ))
  (( DURATION < 1 )) && DURATION=1

  HIT_QUOTA="false"
  QUOTA_LOG_MATCH="false"
  tail_clean=""
  if [[ -f "$RUN_LOG" ]]; then
    tail_clean=$(tail -c +"$((RUN_LOG_OFFSET + 1))" "$RUN_LOG" 2>/dev/null | tail -n 50 | tr -d '\r' | sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g' || true)
  fi
  if [[ -n "$tail_clean" ]] && (( EXIT_CODE != 0 )) && grep -Eiq "$QUOTA_EXHAUSTION_RE" <<<"$tail_clean"; then
    QUOTA_LOG_MATCH="true"
    HIT_QUOTA="true"
    rst_epoch=$(parse_reset_epoch_from_log "$tail_clean")
    mark_account_exhausted "$SELECTED_USER" "$rst_epoch"
    echo "[fm-agy-pool] Account '$SELECTED_USER' hit quota exhaustion; marked exhausted until ${rst_epoch:-default-window}." >&2
  elif [[ $EXIT_CODE -eq 42 ]]; then
    HIT_QUOTA="true"
  fi

  record_run "$SELECTED_USER" "$DURATION" "$HIT_QUOTA"
  if [[ "${AGY_ARGS[0]:-}" != models ]]; then
    _end_group=$(model_usage_group "${ROUTE_MODEL:-}")
    if _end_detail=$(query_live_usage_detail "$SELECTED_USER" "$_end_group"); then
      IFS='|' read -r _epct _erest _ewk _ewkr _efh _efhr <<<"$_end_detail"
      if [[ "$_epct" =~ ^[0-9]+$ ]]; then
        _erst=$(reset_to_epoch "$_erest")
        save_account_quota "$SELECTED_USER" "$_end_group" "$_epct" "$_erest" "$_ewk" "$_ewkr" "$_efh" "$_efhr" "$_erst"
        if (( _epct <= MIN_REMAINING_PCT )); then
          mark_account_exhausted "$SELECTED_USER" "$_erst"
        fi
      fi
      log_usage_event "quota_end" "$SELECTED_USER" "$_end_group" "$_epct" "$_erest" "$_ewk" "$_ewkr" "$_efh" "$_efhr"
    else
      log_usage_event "quota_end" "$SELECTED_USER" "$_end_group" "" "" "" "" "" ""
    fi
  fi
  if (( EXIT_CODE == 0 )) && [[ "${AGY_ARGS[0]:-}" != models ]]; then
    record_conversation_owner "$SELECTED_USER" "$(tail -c +"$((RUN_LOG_OFFSET + 1))" "$RUN_LOG" 2>/dev/null | tail -n 200 || true)"
  fi
  AFTER_PCT=$(get_remaining_pct "$SELECTED_USER" "$ROUTE_MODEL")

  if [[ -d "$(dirname "$USAGE_LOG")" ]]; then
    jq -nc \
      --arg ts "$(date -Iseconds)" \
      --arg user "$SELECTED_USER" \
      --arg model "${ROUTE_MODEL:-default}" \
      --arg task "$TASK_LABEL" \
      --argjson dur "$DURATION" \
      --argjson rc "$EXIT_CODE" \
      --argjson pct "$AFTER_PCT" \
      --argjson quota "$HIT_QUOTA" \
      '{ts: $ts, provider: "google-ai-pro-direct", user: $user, model: $model, task: $task, duration_sec: $dur, exit_code: $rc, est_remaining_pct: $pct, quota_hit: $quota}' \
      >> "$USAGE_LOG" 2>/dev/null || true
  fi

  if [[ "$QUOTA_LOG_MATCH" == "true" && "$IS_INTERACTIVE" -eq 0 && -z "$EXPLICIT_USER" && "${AGY_ARGS[0]:-}" != models ]]; then
    RETRIED_AFTER_QUOTA=1
    echo "[fm-agy-pool] Rotating away from exhausted account '$SELECTED_USER' to next eligible account..." >&2
    continue
  fi
  break
done

exit "$EXIT_CODE"
