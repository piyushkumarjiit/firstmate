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
# from each account's cached `agy models` catalog.
AGY_BIN="${AGY_BIN:-/usr/local/bin/agy}"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
STATE_DIR="${FM_AGY_STATE_DIR:-/tmp/fm-agy-pool}"
USAGE_LOG="${FM_AGY_USAGE_LOG:-/var/log/firstmate/agy-usage.jsonl}"
MIN_REMAINING_PCT="${FM_AGY_MIN_PCT:-15}"         # Switch accounts when <= 15% left
WINDOW_SECONDS="${FM_AGY_WINDOW_SEC:-18000}"       # Fallback 5-hour rolling window
DEFAULT_BUDGET_SEC="${FM_AGY_BUDGET_SEC:-5400}"    # Fallback budget
MODELS_TTL="${FM_AGY_MODELS_TTL:-86400}"           # 24h catalog cache TTL
PACING_SECONDS="${FM_AGY_PACING_SEC:-60}"          # Min gap across different accounts
LIVE_TIMEOUT="${FM_AGY_LIVE_TIMEOUT:-30}"          # Per-query timeout seconds
MAX_ACTIVE="${FM_AGY_MAX_ACTIVE:-2}"
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

list_contains() {
  local needle="$1" item
  shift
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

is_authenticated() {
  sudo -n -u "$1" test -s "/home/${1}/.gemini/antigravity-cli/antigravity-oauth-token" 2>/dev/null
}

model_usage_group() {
  case "${1,,}" in
    gpt*|claude*) printf '%s\n' "Claude and GPT models" ;;
    *) printf '%s\n' "Gemini Models" ;;
  esac
}

is_neon_model() {
  case "${1,,}" in
    *neon*) return 0 ;;
    *) return 1 ;;
  esac
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

get_sticky_user() {
  local sfile="$STATE_DIR/last-active"
  [[ -f "$sfile" ]] || return 0
  head -n 1 "$sfile" 2>/dev/null | tr -d '[:space:]' || true
}

record_sticky_user() {
  [[ -n "${1:-}" ]] || return 0
  local sfile="$STATE_DIR/last-active"
  printf '%s\n' "$1" > "$sfile" 2>/dev/null || true
  chmod 0666 "$sfile" 2>/dev/null || true
}

# --- Per-account local state & quota persistence ---

write_state_file() {
  local user="$1" ws="$2" ra="$3" us="$4" bg="$5" ex="$6" prune="${7:-}"
  local qfile="$STATE_DIR/${user}.state.json" updated=""
  if [[ -f "$qfile" ]]; then
    updated=$(jq --arg u "$user" --argjson ws "$ws" --argjson ra "$ra" \
      --argjson us "$us" --argjson bg "$bg" --argjson ex "$ex" --arg prune "$prune" \
      '{user: $u, window_start: $ws, reset_at: $ra, used_sec: $us, budget_sec: $bg, exhausted: $ex}
       + (if .quota then {quota: (if $prune != "" then (.quota | with_entries(select((.value.reset_at // 0) <= 0 or ($prune | tonumber) < (.value.reset_at // 0)))) else .quota end)} else {} end)' \
      "$qfile" 2>/dev/null || true)
  fi
  if [[ -n "$updated" ]]; then
    printf '%s\n' "$updated" > "$qfile"
  else
    jq -n --arg u "$user" --argjson ws "$ws" --argjson ra "$ra" \
      --argjson us "$us" --argjson bg "$bg" --argjson ex "$ex" \
      '{user: $u, window_start: $ws, reset_at: $ra, used_sec: $us, budget_sec: $bg, exhausted: $ex}' > "$qfile"
  fi
  chmod 0666 "$qfile" 2>/dev/null || true
}

init_or_roll_window() {
  local user="$1" qfile="$STATE_DIR/${1}.state.json" now
  now=$(now_epoch)
  if [[ ! -f "$qfile" ]]; then
    write_state_file "$user" 0 0 0 "$DEFAULT_BUDGET_SEC" false
    return
  fi
  local reset_at=0 budget="$DEFAULT_BUDGET_SEC"
  IFS='|' read -r reset_at budget < <(
    jq -r --argjson db "$DEFAULT_BUDGET_SEC" \
      '[(.reset_at // 0), (.budget_sec // $db)] | map(tostring) | join("|")' "$qfile" 2>/dev/null || printf '0|%s\n' "$DEFAULT_BUDGET_SEC"
  ) || true
  [[ "$reset_at" =~ ^[0-9]+$ ]] || reset_at=0
  [[ "$budget" =~ ^[0-9]+$ ]] || budget=$DEFAULT_BUDGET_SEC
  if (( reset_at > 0 && now >= reset_at )); then
    write_state_file "$user" 0 0 0 "$budget" false "$now"
  fi
}

get_remaining_pct() {
  local user="$1" qfile="$STATE_DIR/${1}.state.json"
  init_or_roll_window "$user"
  local exhausted=false used=0 budget="$DEFAULT_BUDGET_SEC"
  IFS='|' read -r exhausted used budget < <(
    jq -r --argjson db "$DEFAULT_BUDGET_SEC" \
      '[(.exhausted // false), (.used_sec // 0), (.budget_sec // $db)] | map(tostring) | join("|")' "$qfile" 2>/dev/null || printf 'false|0|%s\n' "$DEFAULT_BUDGET_SEC"
  ) || true
  if [[ "$exhausted" == "true" ]]; then
    echo 0
    return
  fi
  # Only agy /usage or a failed run's quota error marks an account exhausted;
  # local time-used is telemetry unless FM_AGY_LOCAL_ESTIMATE=on.
  if [[ "${FM_AGY_LOCAL_ESTIMATE:-off}" != on ]]; then
    echo 100
    return
  fi
  [[ "$used" =~ ^[0-9]+$ ]] || used=0
  [[ "$budget" =~ ^[0-9]+$ ]] && (( budget > 0 )) || budget=$DEFAULT_BUDGET_SEC
  local pct=$(( 100 - (used * 100 / budget) ))
  (( pct < 0 )) && pct=0
  echo "$pct"
}

is_user_exhausted() {
  local pct
  pct=$(get_remaining_pct "$1")
  (( pct <= MIN_REMAINING_PCT ))
}

# Read-only check: is the account's recorded exhaustion window still open.
account_marked_exhausted() {
  local qfile="$STATE_DIR/${1}.state.json" exhausted=false reset_at=0
  [[ -f "$qfile" ]] || return 1
  IFS='|' read -r exhausted reset_at < <(
    jq -r '[(.exhausted // false), (.reset_at // 0)] | map(tostring) | join("|")' "$qfile" 2>/dev/null || echo "false|0"
  ) || true
  [[ "$exhausted" == true ]] || return 1
  [[ "$reset_at" =~ ^[0-9]+$ ]] && (( reset_at > 0 && $(now_epoch) >= reset_at )) && return 1
  return 0
}

record_run() {
  local user="$1" dur="$2" qfile="$STATE_DIR/${1}.state.json" now
  init_or_roll_window "$user"
  now=$(now_epoch)
  local wstart=0 reset_at=0 used=0 budget="$DEFAULT_BUDGET_SEC" exhausted=false
  IFS='|' read -r wstart reset_at used budget exhausted < <(
    jq -r --argjson db "$DEFAULT_BUDGET_SEC" \
      '[(.window_start // 0), (.reset_at // 0), (.used_sec // 0), (.budget_sec // $db), (.exhausted // false)] | map(tostring) | join("|")' \
      "$qfile" 2>/dev/null || printf '0|0|0|%s|false\n' "$DEFAULT_BUDGET_SEC"
  ) || true
  [[ "$wstart" =~ ^[0-9]+$ ]] || wstart=0
  [[ "$reset_at" =~ ^[0-9]+$ ]] || reset_at=0
  [[ "$used" =~ ^[0-9]+$ ]] || used=0
  [[ "$budget" =~ ^[0-9]+$ ]] || budget=$DEFAULT_BUDGET_SEC
  [[ "$exhausted" == "true" ]] || exhausted=false
  if (( wstart == 0 )); then
    wstart=$now
    reset_at=$(( now + WINDOW_SECONDS ))
  fi
  write_state_file "$user" "$wstart" "$reset_at" "$(( used + dur ))" "$budget" "$exhausted"
}

mark_account_exhausted() {
  local user="$1" reset_epoch="${2:-0}" qfile="$STATE_DIR/${1}.state.json" now
  now=$(now_epoch)
  (( reset_epoch <= 0 )) && reset_epoch=$(( now + WINDOW_SECONDS ))
  init_or_roll_window "$user"
  local used=0 budget="$DEFAULT_BUDGET_SEC"
  IFS='|' read -r used budget < <(
    jq -r --argjson db "$DEFAULT_BUDGET_SEC" \
      '[(.used_sec // 0), (.budget_sec // $db)] | map(tostring) | join("|")' "$qfile" 2>/dev/null || printf '0|%s\n' "$DEFAULT_BUDGET_SEC"
  ) || true
  [[ "$used" =~ ^[0-9]+$ ]] || used=0
  [[ "$budget" =~ ^[0-9]+$ ]] || budget=$DEFAULT_BUDGET_SEC
  write_state_file "$user" "$now" "$reset_epoch" "$used" "$budget" true
}

save_account_quota() {
  local user="$1" group="$2" min_pct="$3" min_reset="$4" wk_pct="$5" wk_reset="$6" fh_pct="$7" fh_reset="$8" rst_epoch="${9:-0}"
  init_or_roll_window "$user"
  local qfile="$STATE_DIR/${user}.state.json" now min_val="null" wk_val="null" fh_val="null"
  now=$(now_epoch)
  [[ "$min_pct" =~ ^[0-9]+$ ]] && min_val="$min_pct"
  [[ "$wk_pct" =~ ^[0-9]+$ ]] && wk_val="$wk_pct"
  [[ "$fh_pct" =~ ^[0-9]+$ ]] && fh_val="$fh_pct"
  [[ "$rst_epoch" =~ ^[0-9]+$ ]] || rst_epoch=0

  local updated
  updated=$(jq \
    --arg g "$group" --argjson mp "$min_val" --arg mr "${min_reset:-}" --argjson ra "$rst_epoch" \
    --argjson wp "$wk_val" --arg wr "${wk_reset:-}" --argjson fp "$fh_val" --arg fr "${fh_reset:-}" \
    --argjson ca "$now" \
    '.quota = ((.quota // {}) + {($g): {min_pct: $mp, reset: $mr, reset_at: $ra, weekly_pct: $wp, weekly_reset: $wr, five_hour_pct: $fp, five_hour_reset: $fr, checked_at: $ca}})' \
    "$qfile" 2>/dev/null || true)
  if [[ -n "$updated" ]]; then
    printf '%s\n' "$updated" > "$qfile"
    chmod 0666 "$qfile" 2>/dev/null || true
  fi
}

# Read-only lookup of last recorded quota reading for (user, group).
# Prints "<pct>|<reset_at>|<exhausted>" (pct empty when unknown/expired).
get_last_quota_reading() {
  local user="$1" group="${2:-Gemini Models}" qfile="$STATE_DIR/${1}.state.json"
  local now pct="" rst_at=0 exh=false
  now=$(now_epoch)

  if [[ -f "$qfile" ]]; then
    local qline
    qline=$(jq -r --arg g "$group" \
      '(.exhausted // false) as $ex | (.reset_at // 0) as $sra | (.quota[$g] // null) as $q |
       if $q != null then [($q.min_pct // ""), ($q.reset_at // $sra), $ex] else ["", $sra, $ex] end | map(tostring) | join("|")' \
      "$qfile" 2>/dev/null || true)
    if [[ -n "$qline" ]]; then IFS='|' read -r pct rst_at exh <<<"$qline" || true; fi
    [[ "$rst_at" =~ ^[0-9]+$ ]] || rst_at=0
    if (( rst_at > 0 && now >= rst_at )); then
      pct=""; exh=false; rst_at=0
    fi
  fi

  if [[ -z "$pct" && "$exh" != "true" && -f "$USAGE_LOG" ]]; then
    local l_pct="" l_rst="" l_rst_ep=0
    IFS='|' read -r l_pct l_rst < <(
      jq -sr --arg u "$user" --arg g "$group" \
        '([.[] | select(.user == $u and (.event == "usage_check" or .event == "quota_end") and ((.group // "Gemini Models") == $g) and .gemini_min_pct != null)] | last) // empty | [(.gemini_min_pct // ""), (.reset // "")] | map(tostring) | join("|")' \
        "$USAGE_LOG" 2>/dev/null || true
    ) || true
    if [[ "$l_pct" =~ ^[0-9]+$ ]]; then
      if [[ -n "$l_rst" ]]; then
        l_rst_ep=$(date -d "$l_rst" +%s 2>/dev/null || echo 0)
        [[ "$l_rst_ep" =~ ^[0-9]+$ ]] || l_rst_ep=0
      fi
      if (( l_rst_ep == 0 || now < l_rst_ep )); then
        pct="$l_pct"; rst_at="$l_rst_ep"
      fi
    fi
  fi

  printf '%s|%s|%s\n' "$pct" "$rst_at" "$exh"
}

# --- Machine-wide locked and paced live agy query ---

# Serialize every live agy query (models and /usage) across all homes and tasks
# on this host under one flock file, enforcing PACING_SECONDS between queries on
# different accounts (same-account back-to-back queries are not gapped).
# The gap exists because one host and IP issuing the same command on several
# accounts at once risks Google banning those accounts.
run_live_agy_query() {
  local user="$1"
  shift
  local lockfile="$STATE_DIR/live-query.lock" last_file="$STATE_DIR/last-live-query"
  if [[ ! -e "$lockfile" ]]; then
    : > "$lockfile" 2>/dev/null || true
    chmod 0666 "$lockfile" 2>/dev/null || true
  fi
  local rc=0
  (
    flock -x 9
    local last_ts="" last_user="" now elapsed
    if [[ -f "$last_file" ]]; then
      IFS=$'\t' read -r last_ts last_user < "$last_file" || true
    fi
    if [[ -n "$last_user" && "$last_user" != "$user" && "$PACING_SECONDS" -gt 0 && "$last_ts" =~ ^[0-9]+$ ]]; then
      now=$(now_epoch)
      elapsed=$(( now - last_ts ))
      if (( elapsed >= 0 && elapsed < PACING_SECONDS )); then
        sleep "$(( PACING_SECONDS - elapsed ))"
      fi
    fi
    local qrc=0
    local -a cmd=(sudo -n -u "$user" -H "$AGY_BIN" "$@")
    if command -v timeout >/dev/null 2>&1 && (( LIVE_TIMEOUT > 0 )); then
      cmd=(timeout "$LIVE_TIMEOUT" "${cmd[@]}")
    fi
    "${cmd[@]}" </dev/null 2>/dev/null || qrc=$?
    printf '%s\t%s\n' "$(now_epoch)" "$user" > "$last_file" 2>/dev/null || true
    chmod 0666 "$last_file" 2>/dev/null || true
    exit "$qrc"
  ) 9>>"$lockfile" || rc=$?
  return "$rc"
}

# --- Per-account model catalog cache (read-only queries + TTL refresh) ---

catalog_cache_status() {
  local cfile="$STATE_DIR/${1}.models.json" fetched="" count=0
  [[ -f "$cfile" ]] || { echo "missing"; return 0; }
  IFS='|' read -r fetched count < <(
    jq -r '[(.fetched_at // ""), ((.models // []) | if type == "array" then length else 0 end)] | map(tostring) | join("|")' "$cfile" 2>/dev/null || true
  ) || true
  if [[ ! "$fetched" =~ ^[0-9]+$ ]] || [[ ! "$count" =~ ^[0-9]+$ ]] || (( count == 0 )); then
    echo "missing"
  elif (( $(now_epoch) - fetched < MODELS_TTL )); then
    echo "fresh"
  else
    echo "stale"
  fi
}

catalog_has_model() {
  local cfile="$STATE_DIR/${1}.models.json"
  [[ -f "$cfile" ]] && jq -e --arg m "$2" '(.models // []) | index($m) != null' "$cfile" >/dev/null 2>&1
}

catalog_is_reserved() {
  local cfile="$STATE_DIR/${1}.models.json"
  [[ -f "$cfile" ]] && jq -e '(.models // []) | any(ascii_downcase | contains("neon"))' "$cfile" >/dev/null 2>&1
}

parse_agy_models_output() {
  tr -d '\r' | awk -F'\t' '{
    id = (NF >= 2) ? $1 : $0
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", id)
    if (id ~ /^[A-Za-z0-9][A-Za-z0-9._-]+$/ && tolower(id) !~ /^(error|warning|notice|fetching)$/ && !seen[id]++) print id
  }'
}

# Refresh one account's catalog only when absent or older than MODELS_TTL.
# Failed fetches keep any previous cache and return non-zero (uncertainty).
ensure_account_catalog() {
  local user="$1"
  [[ "$(catalog_cache_status "$user")" == "fresh" ]] && return 0

  local raw_models rc=0
  raw_models=$(run_live_agy_query "$user" models) || rc=$?
  local -a parsed=()
  if (( rc == 0 )) && [[ -n "$raw_models" ]]; then
    mapfile -t parsed < <(parse_agy_models_output <<<"$raw_models")
  fi
  if (( rc == 0 && ${#parsed[@]} > 0 )); then
    local cfile="$STATE_DIR/${user}.models.json" tmp json
    json=$(printf '%s\n' "${parsed[@]}" | jq -R . | jq -s --arg u "$user" --argjson ts "$(now_epoch)" '{user: $u, fetched_at: $ts, models: .}')
    tmp=$(mktemp "$STATE_DIR/.${user}.models.XXXXXX" 2>/dev/null || true)
    if [[ -n "$tmp" ]]; then
      printf '%s\n' "$json" > "$tmp"
      chmod 0666 "$tmp" 2>/dev/null || true
      mv -f "$tmp" "$cfile" 2>/dev/null || { cat "$tmp" > "$cfile"; rm -f "$tmp"; }
    else
      printf '%s\n' "$json" > "$cfile"
    fi
    chmod 0666 "$cfile" 2>/dev/null || true
    return 0
  fi

  echo "[fm-agy-pool] Notice: model catalog fetch for '$user' failed or returned no models (exit $rc); catalog is uncertain (keeping any prior cache)." >&2
  return 1
}

# A catalog that cannot be refreshed is uncertainty, not refusal: a caller that
# already targets an account (reuse or conversation affinity) may still use it.
is_user_allowed_for_model() {
  local user="$1" model="${2:-}"
  [[ -z "$model" || "$model" == "default" ]] && return 0
  ensure_account_catalog "$user" || return 0
  catalog_has_model "$user" "$model"
}

# --- Quota parse + live start/end/gate/manual recording ---

# Parse `agy -p /usage` output for a model group into:
#   min_pct|min_reset|weekly_pct|weekly_reset|five_hour_pct|five_hour_reset
parse_live_usage_output() {
  local group="${1:-Gemini Models}"
  tr -d '\r' | awk -F'\t' -v grp="$group" '
  BEGIN { min_pct = 999; min_reset = ""; count = 0; wk_pct = ""; wk_reset = ""; fh_pct = ""; fh_reset = "" }
  tolower($1) == tolower(grp) {
    label = tolower($2)
    pct = $3; gsub(/[^0-9]/, "", pct)
    reset = $4; gsub(/^[[:space:]]+|[[:space:]]+$/, "", reset)
    if (pct != "") {
      pct_val = pct + 0; count++
      if (pct_val < min_pct) { min_pct = pct_val; min_reset = reset }
      if (label ~ /weekly/) { wk_pct = pct_val; wk_reset = reset }
      else if (label ~ /five[[:space:]_-]*hour/) { fh_pct = pct_val; fh_reset = reset }
    }
  }
  END {
    if (count > 0 && min_pct != 999) printf "%s|%s|%s|%s|%s|%s\n", min_pct, min_reset, wk_pct, wk_reset, fh_pct, fh_reset
    else exit 1
  }'
}

query_live_usage_detail() {
  local user="$1" group="${2:-Gemini Models}" verbose="${3:-false}" raw_output parsed
  raw_output=$(run_live_agy_query "$user" -p /usage || true)
  [[ -n "$raw_output" ]] || return 1
  parsed=$(parse_live_usage_output "$group" <<<"$raw_output") || return 1
  if [[ "$verbose" == "true" ]]; then
    awk -F'\t' -v grp="$group" 'tolower($1) == tolower(grp)' <<<"$raw_output" || true
  fi
  printf '%s\n' "$parsed"
}

log_usage_event() {
  local event="$1" account="$2" group="$3" min_pct="$4" reset="$5" wk_pct="$6" wk_reset="$7" fh_pct="$8" fh_reset="$9" decision="${10:-}"
  [[ -d "$(dirname "$USAGE_LOG")" ]] || return 0
  local pct_val="null" wk_val="null" fh_val="null"
  [[ "$min_pct" =~ ^[0-9]+$ ]] && pct_val="$min_pct"
  [[ "$wk_pct" =~ ^[0-9]+$ ]] && wk_val="$wk_pct"
  [[ "$fh_pct" =~ ^[0-9]+$ ]] && fh_val="$fh_pct"
  jq -nc \
    --arg ts "$(date -Iseconds)" --arg user "$account" \
    --arg model "${ROUTE_MODEL:-default}" --arg task "${FM_TASK_ID:-}" \
    --arg ev "$event" --arg grp "$group" --arg dec "$decision" \
    --arg reset "${reset:-}" --arg wr "${wk_reset:-}" --arg fr "${fh_reset:-}" \
    --argjson pct "$pct_val" --argjson wp "$wk_val" --argjson fp "$fh_val" \
    '{ts: $ts, provider: "google-ai-pro-direct", user: $user, model: $model, task: $task, event: $ev, group: $grp, gemini_min_pct: $pct, reset: $reset, weekly_pct: $wp, weekly_reset: $wr, five_hour_pct: $fp, five_hour_reset: $fr}
     + (if $dec != "" then {decision: $dec} else {} end)' \
    >> "$USAGE_LOG" 2>/dev/null || true
}

# Single owner for querying live /usage, persisting quota state, marking low
# accounts exhausted, and appending the JSONL record. Sets _LIVE_PCT and
# _LIVE_RESET. Modes:
#   gate   - log usage_check start/skip/unknown; return 2 when <= floor
#   start  - log usage_check start/unknown (already-active reuse)
#   end    - log quota_end (post-task reading)
#   manual - print verbose lines + "<pct> <reset>", log usage_check manual;
#            return 1 on query failure
record_live_quota() {
  local mode="$1" user="$2" group="${3:-Gemini Models}" verbose="false"
  [[ "$mode" == "manual" ]] && verbose="true"
  _LIVE_PCT="" _LIVE_RESET=""

  local raw detail wk_pct="" wk_reset="" fh_pct="" fh_reset=""
  if ! raw=$(query_live_usage_detail "$user" "$group" "$verbose"); then
    case "$mode" in
      manual) return 1 ;;
      end)    log_usage_event "quota_end" "$user" "$group" "" "" "" "" "" "" ;;
      *)      log_usage_event "usage_check" "$user" "$group" "" "" "" "" "" "" "unknown" ;;
    esac
    return 0
  fi

  if [[ "$mode" == "manual" ]]; then
    local line_count
    line_count=$(wc -l <<<"$raw")
    if (( line_count > 1 )); then
      head -n $(( line_count - 1 )) <<<"$raw"
    fi
    detail=$(tail -n 1 <<<"$raw")
  else
    detail="$raw"
  fi

  IFS='|' read -r _LIVE_PCT _LIVE_RESET wk_pct wk_reset fh_pct fh_reset <<<"$detail" || true
  if [[ "$mode" == "manual" ]]; then
    printf '%s %s\n' "$_LIVE_PCT" "$_LIVE_RESET"
  fi

  local rst_epoch=0 low=0
  if [[ "$_LIVE_PCT" =~ ^[0-9]+$ ]]; then
    rst_epoch=$(reset_to_epoch "$_LIVE_RESET")
    save_account_quota "$user" "$group" "$_LIVE_PCT" "$_LIVE_RESET" "$wk_pct" "$wk_reset" "$fh_pct" "$fh_reset" "$rst_epoch"
    if (( _LIVE_PCT <= MIN_REMAINING_PCT )); then
      low=1
      mark_account_exhausted "$user" "$rst_epoch"
    fi
  fi

  case "$mode" in
    end)    log_usage_event "quota_end" "$user" "$group" "$_LIVE_PCT" "$_LIVE_RESET" "$wk_pct" "$wk_reset" "$fh_pct" "$fh_reset" ;;
    manual) log_usage_event "usage_check" "$user" "$group" "$_LIVE_PCT" "$_LIVE_RESET" "$wk_pct" "$wk_reset" "$fh_pct" "$fh_reset" "manual" ;;
    start)  log_usage_event "usage_check" "$user" "$group" "$_LIVE_PCT" "$_LIVE_RESET" "$wk_pct" "$wk_reset" "$fh_pct" "$fh_reset" "start" ;;
    gate)
      if (( low == 1 )); then
        log_usage_event "usage_check" "$user" "$group" "$_LIVE_PCT" "$_LIVE_RESET" "$wk_pct" "$wk_reset" "$fh_pct" "$fh_reset" "skip"
        return 2
      fi
      log_usage_event "usage_check" "$user" "$group" "$_LIVE_PCT" "$_LIVE_RESET" "$wk_pct" "$wk_reset" "$fh_pct" "$fh_reset" "start"
      ;;
  esac
  return 0
}

# --- Account selection ---

# Evaluate one candidate account for model support (refreshing stale/missing
# catalog once) and live /usage check (once). Returns 0 on accept, 2 if deferred
# as reserved, 1 otherwise. Uses caller-scoped _EVAL_PICKED _EVAL_LIVE_PCT
# _CHECKED_MODELS _CHECKED_USAGE _DEFERRED_RESERVED.
evaluate_candidate_account() {
  local u="$1" model="$2" group="$3" allow_reserved="$4"
  _EVAL_PICKED="" _EVAL_LIVE_PCT=""
  local want_neon=0
  is_neon_model "$model" && want_neon=1

  case " $_CHECKED_USAGE " in *" $u "*) return 1 ;; esac
  id "$u" >/dev/null 2>&1 || return 1
  is_authenticated "$u" || return 1
  is_user_exhausted "$u" && return 1

  local last_pct="" last_exh=false
  IFS='|' read -r last_pct _ last_exh < <(get_last_quota_reading "$u" "$group") || true
  [[ "$last_exh" == "true" ]] && return 1
  if [[ "$last_pct" =~ ^[0-9]+$ ]] && (( last_pct <= MIN_REMAINING_PCT )); then
    return 1
  fi

  local catalog_ok=1
  case " $_CHECKED_MODELS " in
    *" $u "*) [[ "$(catalog_cache_status "$u")" != "missing" ]] || catalog_ok=0 ;;
    *)
      _CHECKED_MODELS="$_CHECKED_MODELS $u"
      ensure_account_catalog "$u" || catalog_ok=0
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
  local lrc=0
  record_live_quota gate "$u" "$group" || lrc=$?
  if (( lrc == 2 )); then
    echo "[fm-agy-pool] Account '$u' live quota is ${_LIVE_PCT}% (floor=${MIN_REMAINING_PCT}%), exhausted until ${_LIVE_RESET}; skipping to next account." >&2
    return 1
  fi
  _EVAL_PICKED="$u"
  _EVAL_LIVE_PCT="$_LIVE_PCT"
  return 0
}

# Order accounts: sticky first, then known quota descending, then unknown in config order.
sort_candidates_by_quota() {
  local group="$1" sticky="$2"
  shift 2
  local -a rows=()
  local idx=0 u pct key
  for u in "$@"; do
    idx=$(( idx + 1 ))
    IFS='|' read -r pct _ _ < <(get_last_quota_reading "$u" "$group") || true
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

try_candidate_pool() {
  local model="$1" group="$2" sticky="$3" allow_reserved="$4"
  shift 4
  (( $# > 0 )) || return 1
  local -a ordered=()
  mapfile -t ordered < <(sort_candidates_by_quota "$group" "$sticky" "$@")
  local u rc
  for u in ${ordered[@]+"${ordered[@]}"}; do
    rc=0
    evaluate_candidate_account "$u" "$model" "$group" "$allow_reserved" || rc=$?
    if (( rc == 0 )) && [[ -n "$_EVAL_PICKED" ]]; then
      printf '%s|%s\n' "$_EVAL_PICKED" "$_EVAL_LIVE_PCT"
      return 0
    fi
  done
  return 1
}

pick_sticky_user() {
  local model="${1:-}" explicit_user="${2:-${FM_AGY_USER:-}}" group
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
    if is_user_exhausted "$explicit_user"; then
      echo "[fm-agy-pool] ERROR: Requested user '$explicit_user' is marked exhausted for model '${model:-default}'." >&2
      return 1
    fi
    if [[ -n "$model" && "$model" != "default" ]] && ensure_account_catalog "$explicit_user"; then
      if ! catalog_has_model "$explicit_user" "$model"; then
        echo "[fm-agy-pool] ERROR: Requested user '$explicit_user' catalog does not list model '$model'." >&2
        return 1
      fi
    fi
    local lrc=0
    record_live_quota gate "$explicit_user" "$group" || lrc=$?
    if (( lrc == 2 )); then
      echo "[fm-agy-pool] ERROR: Requested user '$explicit_user' quota is ${_LIVE_PCT}% (floor=${MIN_REMAINING_PCT}%), exhausted until ${_LIVE_RESET}." >&2
      return 1
    fi
    printf '%s|%s\n' "$explicit_user" "$_LIVE_PCT"
    return 0
  fi

  local sticky want_neon=0
  sticky=$(get_sticky_user)
  is_neon_model "$model" && want_neon=1

  local _CHECKED_MODELS="" _CHECKED_USAGE="" _DEFERRED_RESERVED="" _EVAL_PICKED="" _EVAL_LIVE_PCT=""
  local -a tier1_pool=() known_reserved=()
  local u cstat
  for u in "${GPRO_USERS[@]}"; do
    cstat=$(catalog_cache_status "$u")
    if [[ "$cstat" == "fresh" && -n "$model" && "$model" != "default" ]]; then
      catalog_has_model "$u" "$model" || continue
    fi
    if (( want_neon == 0 )) && [[ "$cstat" != "missing" ]] && catalog_is_reserved "$u"; then
      known_reserved+=("$u")
    else
      tier1_pool+=("$u")
    fi
  done

  if try_candidate_pool "$model" "$group" "$sticky" "$want_neon" ${tier1_pool[@]+"${tier1_pool[@]}"}; then
    return 0
  fi

  if (( want_neon == 0 )); then
    local -a tier2_pool=()
    local d
    for d in ${known_reserved[@]+"${known_reserved[@]}"} $_DEFERRED_RESERVED; do
      [[ -n "$d" ]] || continue
      list_contains "$d" ${tier2_pool[@]+"${tier2_pool[@]}"} || tier2_pool+=("$d")
    done
    if try_candidate_pool "$model" "$group" "$sticky" 1 ${tier2_pool[@]+"${tier2_pool[@]}"}; then
      return 0
    fi
  fi

  return 1
}

# Per-account live process check only (no network).
account_has_live_agy() {
  "${FM_AGY_PGREP:-pgrep}" -u "$1" -x agy >/dev/null 2>&1
}

find_active_pool_users() {
  local -a active=()
  local u
  for u in "${GPRO_USERS[@]}"; do
    account_has_live_agy "$u" && active+=("$u")
  done
  if (( ${#active[@]} > 0 )); then
    printf '%s\n' "${active[@]}"
  fi
}

# --- Subcommands (--usage, --status, --reset, --check-*) ---

cmd_usage() {
  local target="${1:-}"
  if [[ -z "$target" ]]; then
    echo "[fm-agy-pool] ERROR: --usage requires an account argument (e.g. --usage <account>)." >&2
    exit 1
  fi
  local -a active_users=()
  mapfile -t active_users < <(find_active_pool_users)
  if ! list_contains "$target" ${active_users[@]+"${active_users[@]}"} && (( ${#active_users[@]} >= MAX_ACTIVE )); then
    echo "[fm-agy-pool] ERROR: Another pool account ('${active_users[0]}') is currently active; refusing live usage check for '$target' (${#active_users[@]} pool accounts active, cap is $MAX_ACTIVE (FM_AGY_MAX_ACTIVE))." >&2
    exit 75
  fi
  if ! record_live_quota manual "$target" "Gemini Models"; then
    echo "[fm-agy-pool] ERROR: Failed to query live usage for '$target'." >&2
    exit 1
  fi
  exit 0
}

cmd_status() {
  printf "%-11s %-14s %-16s %-22s %-26s %s\n" "ACCOUNT" "STATUS" "REMAINING" "RESET_AT" "CHECKED_AT" "CATALOG_TIER"
  local u
  for u in "${GPRO_USERS[@]}"; do
    local auth="PENDING_LOGIN"
    id "$u" >/dev/null 2>&1 || auth="MISSING_USER"
    [[ "$auth" == "PENDING_LOGIN" ]] && is_authenticated "$u" && auth="READY"

    local pct="unknown" rst_str="unknown" chk_ts="unknown"
    if [[ -f "$USAGE_LOG" ]]; then
      local p="" r="" t=""
      IFS='|' read -r p r t < <(
        jq -sr --arg u "$u" \
          '([.[] | select(.user == $u and (.event == "usage_check" or .event == "quota_end"))] | last) // empty | [(.gemini_min_pct // ""), (.reset // ""), (.ts // "")] | map(tostring) | join("|")' \
          "$USAGE_LOG" 2>/dev/null || true
      ) || true
      [[ -n "$r" ]] && rst_str="$r"
      [[ -n "$t" ]] && chk_ts="$t"
      if [[ "$p" =~ ^[0-9]+$ ]]; then
        if (( p <= MIN_REMAINING_PCT )); then pct="${p}% (skip)"; else pct="${p}%"; fi
      fi
    fi

    local tier="unknown" cstat
    cstat=$(catalog_cache_status "$u")
    if [[ "$cstat" != "missing" ]]; then
      if catalog_is_reserved "$u"; then tier="reserved (neon)"; else tier="standard"; fi
      [[ "$cstat" == "stale" ]] && tier="$tier,stale"
    fi

    printf "%-11s %-14s %-16s %-22s %-26s %s\n" "$u" "$auth" "$pct" "$rst_str" "$chk_ts" "$tier"
  done
  exit 0
}

# --check-account <account> [<model>]: read-only spawn gate for a named account.
cmd_check_account() {
  local user="${1:-}" model="${2:-${FM_AGY_POOL_MODEL:-}}"
  if [[ -z "$user" ]]; then
    echo "[fm-agy-pool] ERROR: --check-account requires an account argument." >&2
    exit 1
  fi
  if ! list_contains "$user" ${GPRO_USERS[@]+"${GPRO_USERS[@]}"}; then
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

# --check-model <model> [<account>]: read-only spawn-time model probe.
cmd_check_model() {
  local model="${1:-}" user="${2:-}"
  [[ -z "$model" || "$model" == "default" ]] && exit 0
  if [[ -n "$user" ]]; then
    local cstat
    cstat=$(catalog_cache_status "$user")
    if [[ "$cstat" == "fresh" ]]; then
      catalog_has_model "$user" "$model" && exit 0
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
  (( found_fresh == 1 )) && exit 0
  if (( has_unknown == 1 )); then
    echo "[fm-agy-pool] Notice: cached model catalog is unknown for one or more pool accounts; allowing '--model $model' unvalidated." >&2
    exit 0
  fi
  echo "[fm-agy-pool] ERROR: agy model '$model' is not listed in any pool account's cached catalog; choose a listed id or omit --model." >&2
  exit 1
}

# --check-capacity [<account>]: read-only spawn-time capacity gate.
cmd_check_capacity() {
  local target="${1:-}"
  local -a active=()
  mapfile -t active < <(find_active_pool_users)
  if [[ -n "$target" ]] && list_contains "$target" ${active[@]+"${active[@]}"}; then
    exit 0
  fi
  if (( ${#active[@]} >= MAX_ACTIVE )); then
    echo "[fm-agy-pool] ERROR: ${#active[@]} pool accounts already active (${active[*]}); cap is $MAX_ACTIVE (FM_AGY_MAX_ACTIVE). Retry once a pool worker finishes or exits." >&2
    exit 75
  fi
  exit 0
}

case "${1:-}" in
  --usage)          cmd_usage "${2:-}" ;;
  --usage=*)        cmd_usage "${1#*=}" ;;
  --status|--stats) cmd_status ;;
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
  --check-account)  cmd_check_account "${2:-}" "${3:-}" ;;
  --check-model)    cmd_check_model "${2:-}" "${3:-}" ;;
  --check-capacity) cmd_check_capacity "${2:-}" ;;
esac

# --- Launch argument parsing, Claude guard, conversation affinity ---

EXPLICIT_USER="${FM_AGY_USER:-}"
REQ_MODEL=""
REQ_CONVERSATION=""
AGY_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user|--account)      EXPLICIT_USER="${2:-}"; shift 2 ;;
    --user=*|--account=*)  EXPLICIT_USER="${1#*=}"; shift ;;
    --model|-m)            REQ_MODEL="${2:-}"; AGY_ARGS+=("$1" "${2:-}"); shift 2 ;;
    --model=*|-m=*)        REQ_MODEL="${1#*=}"; AGY_ARGS+=("$1"); shift ;;
    --conversation)        REQ_CONVERSATION="${2:-}"; AGY_ARGS+=("$1" "${2:-}"); shift 2 ;;
    --conversation=*)      REQ_CONVERSATION="${1#*=}"; AGY_ARGS+=("$1"); shift ;;
    *)                     AGY_ARGS+=("$1"); shift ;;
  esac
done

ROUTE_MODEL="${REQ_MODEL:-${FM_AGY_POOL_MODEL:-}}"

case "${ROUTE_MODEL,,}" in
  claude*)
    echo "[fm-agy-pool] ERROR: model '$ROUTE_MODEL' is a Claude model; Claude does not run through Antigravity. Use the claude or pi harness." >&2
    exit 2
    ;;
esac

# Conversation affinity: keep resumed conversations on their owning account so
# server-side cache is not dropped.
AGY_HOME_BASE="${FM_AGY_HOME_BASE:-/home}"
CONV_RECORD="$STATE_DIR/conversations.tsv"
CONVERSATION_PINNED=0

conversation_owner() {
  local id="$1" u owner=""
  [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  if [[ -f "$CONV_RECORD" ]]; then
    owner=$(awk -F'\t' -v id="$id" '$1 == id {u = $2} END {if (u != "") print u}' "$CONV_RECORD")
    if [[ -n "$owner" ]] && list_contains "$owner" ${GPRO_USERS[@]+"${GPRO_USERS[@]}"} && is_user_allowed_for_model "$owner" "$ROUTE_MODEL"; then
      printf '%s\n' "$owner"
      return 0
    fi
  fi
  for u in "${GPRO_USERS[@]}"; do
    if [[ -n "$(sudo -n -u "$u" find "$AGY_HOME_BASE/$u/.gemini/antigravity-cli/conversations" -maxdepth 1 -name "*${id}*" -print -quit 2>/dev/null)" ]] \
      && is_user_allowed_for_model "$u" "$ROUTE_MODEL"; then
      printf '%s\n' "$u"
      return 0
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

# Parse reset time from agy log tail ("Resets in 2h48m0s" or "Resets at <ts>").
parse_reset_epoch_from_log() {
  local text="${1:-}" now rst_epoch=0
  now=$(now_epoch)

  local dur_line
  dur_line=$(grep -Eio 'resets?[[:space:]]+in[[:space:]]+[0-9]+[[:space:]]*[dhms]([[:space:]]*[0-9]+[[:space:]]*[dhms])*' <<<"$text" | tail -n 1 || true)
  if [[ -n "$dur_line" ]]; then
    local total_sec
    total_sec=$(awk '{
      s = tolower($0); sub(/^.*resets?[[:space:]]+in[[:space:]]+/, "", s); total = 0
      while (match(s, /^[[:space:]]*[0-9]+[[:space:]]*[dhms]/)) {
        tok = substr(s, RSTART, RLENGTH); unit = substr(tok, length(tok), 1)
        val = tok; gsub(/[^0-9]/, "", val); val += 0
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

select_pool_user() {
  local -a active_users=()
  local active_user picked="" picked_pct=""
  mapfile -t active_users < <(find_active_pool_users)
  if (( ${#active_users[@]} > 0 )); then
    if [[ -n "$EXPLICIT_USER" ]]; then
      for active_user in "${active_users[@]}"; do
        [[ "$EXPLICIT_USER" == "$active_user" ]] || continue
        is_user_allowed_for_model "$active_user" "$ROUTE_MODEL" || continue
        is_user_exhausted "$active_user" && continue
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
        is_user_exhausted "$active_user" && continue
        if (( want_neon == 0 )) && catalog_is_reserved "$active_user"; then
          fit_reserved+=("$active_user")
        else
          fit_normal+=("$active_user")
        fi
      done
      local -a fit_pool=()
      if (( ${#fit_normal[@]} > 0 )); then fit_pool=("${fit_normal[@]}"); else fit_pool=(${fit_reserved[@]+"${fit_reserved[@]}"}); fi
      if (( ${#fit_pool[@]} > 0 )); then
        mapfile -t ordered < <(sort_candidates_by_quota "$group" "$sticky" "${fit_pool[@]}")
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
    record_live_quota start "$picked" "$(model_usage_group "$ROUTE_MODEL")"
    picked_pct="$_LIVE_PCT"
  fi
  [[ -n "$picked" ]] || return 1
  printf '%s|%s\n' "$picked" "$picked_pct"
}

# --- Execution environment setup (logs, schema copies, ACLs, trust, settings) ---

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
# shellcheck disable=SC2329 # invoked by EXIT trap below
cleanup_pool_tmp() {
  [[ "$RUN_LOG_EPHEMERAL" -eq 1 ]] && rm -f "$RUN_LOG"
  (( ${#SCHEMA_COPIES[@]} > 0 )) && rm -f "${SCHEMA_COPIES[@]}"
  [[ -n "${STDIN_BUF:-}" ]] && rm -f "$STDIN_BUF"
  return 0
}
trap cleanup_pool_tmp EXIT
umask 0002

# Hand the pool a world-readable copy of any private --json-schema file; the
# schema holds no secrets.
_fix_args=()
_want_schema=0
for _a in "${AGY_ARGS[@]}"; do
  _sf=""
  if (( _want_schema )) && [[ -f "$_a" ]]; then
    _sf="$_a"
  elif [[ "$_a" == --json-schema=* && -f "${_a#--json-schema=}" ]]; then
    _sf="${_a#--json-schema=}"
  fi
  if [[ -n "$_sf" ]]; then
    _copy=$(mktemp /tmp/fm-agy-schema.XXXXXX)
    cat "$_sf" > "$_copy" && chmod 0644 "$_copy"
    SCHEMA_COPIES+=("$_copy")
    if [[ "$_a" == --json-schema=* ]]; then _a="--json-schema=$_copy"; else _a="$_copy"; fi
  fi
  _want_schema=0
  [[ "$_a" == --json-schema ]] && _want_schema=1
  _fix_args+=("$_a")
done
AGY_ARGS=("${_fix_args[@]}")

# Forward worker environment across sudo env_reset while keeping the pool account's HOME.
FORWARD_ENV=()
while IFS= read -r name; do
  case "$name" in
    PATH|TERM|COLORTERM|LANG|LC_*|TMPDIR|TMP|TEMP|GOTMPDIR|COMPACT_ADVISER_DISABLE|LAVISH_AXI_HOST|TRACEPARENT|FM_*|HERDR_*|TMUX|TMUX_PANE)
      FORWARD_ENV+=("$name=${!name}") ;;
  esac
done < <(compgen -e)

# Grant the shared agents group access to fm-owned /tmp/fm-* temp roots.
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

# Grant only the selected pool account access to this task's data/<task> dir.
grant_task_data() {
  local user=$1 task=${FM_TASK_ID:-} home
  [[ -n "$task" && "$task" =~ ^[A-Za-z0-9._-]+$ ]] || return 0
  home=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
  [[ -d "$home/data/$task" && ! -L "$home/data/$task" && -O "$home/data/$task" ]] || return 0
  setfacl -R -m "u:${user}:rwX" -m "d:u:${user}:rwX" "$home/data/$task" 2>/dev/null || true
}

# Mirror an operator-trusted workspace entry into the pool account's trust store.
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

# Keep shared agents-group access on task state, inbox, data, and git files
# written through mktemp+mv by either the pool worker or the operator.
keep_group_access() {
  local home task=${FM_TASK_ID:-}
  [[ -n "$task" ]] || return 0
  home=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
  [[ -d "$home/state" ]] || return 0
  local dirs=("$home/state")
  [[ -d "$home/data/$task" ]] && dirs+=("$home/data/$task")
  local d me
  me=$(id -un)
  for d in "${dirs[@]}"; do
    [[ -O "$d" ]] && setfacl -m "u:$me:rwX" -m "d:u:$me:rwX" "$d" 2>/dev/null
  done
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

IS_INTERACTIVE=0
for _a in "${AGY_ARGS[@]}"; do
  case "$_a" in
    --prompt-interactive|--prompt-interactive=*|-i) IS_INTERACTIVE=1 ;;
  esac
done

# Hand read-only gh config only to interactive direct-PR and local-only ship workers.
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

# Interactive sessions deliver mid-turn steering and suppress the feedback survey,
# which otherwise replaces the idle input row and makes exit and steering checks
# read unknown.
add_queued_messages_setting() {
  local mode="${FM_AGY_QUEUED_MESSAGES:-send-immediately}" a json
  for a in "${AGY_ARGS[@]}"; do
    case "$a" in --settings|--settings=*) return 0 ;; esac
  done
  (( IS_INTERACTIVE )) || return 0
  json='"showFeedbackSurvey":false'
  [[ "$mode" == queue ]] || json="\"queuedMessages\":\"$mode\",$json"
  AGY_ARGS+=(--settings "{$json}")
}
add_queued_messages_setting

# --- Main execution and quota-rotation loop ---

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
  if [[ "$RUN_LOG_EPHEMERAL" -eq 1 ]]; then : > "$RUN_LOG"; fi
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
    # Interactive worker pane: script(1) preserves the TTY while capturing output.
    _sc_args=(-q -f -e)
    if [[ "$RUN_LOG_EPHEMERAL" -eq 0 ]]; then _sc_args+=(-a); fi
    script "${_sc_args[@]}" -c "$(printf '%q ' "${RUN_CMD[@]}")" "$RUN_LOG"
    EXIT_CODE=$?
  else
    if [[ -n "$STDIN_BUF" ]]; then exec 3<"$STDIN_BUF"; else exec 3<&0; fi
    _tee_args=()
    if [[ "$RUN_LOG_EPHEMERAL" -eq 0 ]]; then _tee_args+=(-a); fi
    "${RUN_CMD[@]}" 2>&1 <&3 | tee ${_tee_args[@]+"${_tee_args[@]}"} "$RUN_LOG"
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
    record_live_quota end "$SELECTED_USER" "$(model_usage_group "${ROUTE_MODEL:-}")"
  fi
  if (( EXIT_CODE == 0 )) && [[ "${AGY_ARGS[0]:-}" != models ]]; then
    record_conversation_owner "$SELECTED_USER" "$(tail -c +"$((RUN_LOG_OFFSET + 1))" "$RUN_LOG" 2>/dev/null | tail -n 200 || true)"
  fi
  AFTER_PCT=$(get_remaining_pct "$SELECTED_USER")

  if [[ -d "$(dirname "$USAGE_LOG")" ]]; then
    jq -nc \
      --arg ts "$(date -Iseconds)" --arg user "$SELECTED_USER" \
      --arg model "${ROUTE_MODEL:-default}" --arg task "$TASK_LABEL" \
      --argjson dur "$DURATION" --argjson rc "$EXIT_CODE" \
      --argjson pct "$AFTER_PCT" --argjson quota "$HIT_QUOTA" \
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
