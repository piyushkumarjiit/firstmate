#!/bin/bash
set -euo pipefail
# The shebang is a direct /bin/bash on purpose: firstmate launches this wrapper
# through the bin/agy-pool/agy symlink, and with a single exec the kernel names
# the process after that path ("agy"). Herdr and firstmate identify a live agy
# worker by that process name; an /usr/bin/env hop would rename it to bash.

# ==============================================================================
# fm-agy-pool.sh
# Model-aware sticky quota router + live Google quota + local fallback telemetry
# ==============================================================================

POOL_CONF="${POOL_CONF:-/etc/firstmate/gpro-pool.conf}"
MODELS_CONF="${MODELS_CONF:-/etc/firstmate/gpro-models.conf}"
AGY_BIN="${AGY_BIN:-/usr/local/bin/agy}"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
STATE_DIR="${FM_AGY_STATE_DIR:-/tmp/fm-agy-pool}"
USAGE_LOG="${FM_AGY_USAGE_LOG:-/var/log/firstmate/agy-usage.jsonl}"
MIN_REMAINING_PCT="${FM_AGY_MIN_PCT:-15}"         # Switch accounts when <= 15% left
WINDOW_SECONDS="${FM_AGY_WINDOW_SEC:-18000}"       # Fallback 5-hour rolling window
DEFAULT_BUDGET_SEC="${FM_AGY_BUDGET_SEC:-5400}"    # Fallback budget (auto-calibrates on 429)

mkdir -p "$STATE_DIR"
chmod 1777 "$STATE_DIR" 2>/dev/null || true

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
    local budget
    budget=$(jq -r ".budget_sec // $DEFAULT_BUDGET_SEC" "$qfile")
    jq -n --arg u "$user" --argjson b "$budget" \
      '{user: $u, window_start: 0, reset_at: 0, used_sec: 0, budget_sec: $b, exhausted: false}' > "$qfile"
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

  jq -n \
    --arg u "$user" \
    --argjson ws "$wstart" \
    --argjson ra "$reset_at" \
    --argjson us "$used" \
    --argjson bg "$budget" \
    --argjson ex "$exhausted" \
    '{user: $u, window_start: $ws, reset_at: $ra, used_sec: $us, budget_sec: $bg, exhausted: $ex}' > "$qfile"
  chmod 0666 "$qfile" 2>/dev/null || true
}

# Return space-separated list of users allowed for a model from MODELS_CONF, or empty if unrestricted
allowed_users_for_model() {
  local model="${1:-}"
  [[ -z "$model" || ! -f "$MODELS_CONF" ]] && return 0

  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    local pattern users_csv
    pattern=$(awk '{print $1}' <<<"$line")
    users_csv=$(awk '{$1=""; sub(/^ +/,""); print}' <<<"$line")
    [[ -z "$pattern" || -z "$users_csv" ]] && continue
    # shellcheck disable=SC2053
    if [[ "$model" == $pattern ]]; then
      printf '%s\n' "${users_csv//,/ }"
      return 0
    fi
  done < "$MODELS_CONF"
}

# Users reserved for special models in MODELS_CONF (deprioritized for general Flash tasks)
is_reserved_user() {
  local u="$1"
  [[ ! -f "$MODELS_CONF" ]] && return 1
  grep -Ev '^\s*(#|$)' "$MODELS_CONF" | awk '{for (i=2; i<=NF; i++) print $i}' | tr ',' '\n' | grep -Fxq "$u"
}

is_hydrogen_or_neon() {
  local model="${1:-}"
  case "${model,,}" in
    *hydrogen*|*neon*) return 0 ;;
    *) return 1 ;;
  esac
}

# Query live usage via `agy -p /usage` for the candidate account.
# Prints "<min_pct> <reset_timestamp>" on success (Gemini Models lines found),
# or exits non-zero if failed or unparsable. When verbose=true, also outputs
# the raw Gemini Models lines first.
query_live_usage() {
  local user="$1"
  local verbose="${2:-false}"
  local raw_output
  raw_output=$(sudo -n -u "$user" -H "$AGY_BIN" -p /usage 2>/dev/null || true)
  [[ -z "$raw_output" ]] && return 1

  local parsed
  parsed=$(awk -F'\t' '
  BEGIN { min_pct = 999; min_reset = ""; count = 0 }
  $1 ~ /^Gemini Models/ {
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
    }
  }
  END {
    if (count > 0 && min_pct != 999) {
      print min_pct, min_reset
    } else {
      exit 1
    }
  }' <<<"$raw_output") || return 1

  if [[ "$verbose" == "true" ]]; then
    grep -E '^Gemini Models' <<<"$raw_output" || true
  fi
  echo "$parsed"
  return 0
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

  jq -n \
    --arg u "$user" \
    --argjson ws "$now" \
    --argjson ra "$reset_epoch" \
    --argjson us "$used" \
    --argjson bg "$budget" \
    --argjson ex true \
    '{user: $u, window_start: $ws, reset_at: $ra, used_sec: $us, budget_sec: $bg, exhausted: $ex}' > "$qfile"
  chmod 0666 "$qfile" 2>/dev/null || true
}

log_usage_check() {
  local account="$1" min_pct="$2" reset="$3" decision="$4"
  [[ -d "$(dirname "$USAGE_LOG")" ]] || return 0

  local pct_val="null"
  if [[ "$min_pct" =~ ^[0-9]+$ ]]; then
    pct_val="$min_pct"
  fi

  jq -nc \
    --arg ts "$(date -Iseconds)" \
    --arg user "$account" \
    --arg model "${ROUTE_MODEL:-default}" \
    --arg task "${FM_TASK_ID:-}" \
    --arg dec "$decision" \
    --arg reset "${reset:-}" \
    --argjson pct "$pct_val" \
    '{ts: $ts, provider: "google-ai-pro-direct", user: $user, model: $model, task: $task, event: "usage_check", gemini_min_pct: $pct, reset: $reset, decision: $dec}' \
    >> "$USAGE_LOG" 2>/dev/null || true
}

pick_sticky_user() {
  local model="${1:-}"
  local explicit_user="${2:-${FM_AGY_USER:-}}"

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
    if ! (is_hydrogen_or_neon "$model" || is_reserved_user "$explicit_user"); then
      local usage_info live_pct live_reset
      if usage_info=$(query_live_usage "$explicit_user"); then
        read -r live_pct live_reset <<<"$usage_info"
        if [[ -n "$live_pct" && live_pct -le MIN_REMAINING_PCT ]]; then
          log_usage_check "$explicit_user" "$live_pct" "$live_reset" "skip"
          local rst_epoch
          rst_epoch=$(date -d "$live_reset" +%s 2>/dev/null || echo 0)
          (( rst_epoch <= 0 )) && rst_epoch=$(( $(now_epoch) + WINDOW_SECONDS ))
          mark_account_exhausted "$explicit_user" "$rst_epoch"
          echo "[fm-agy-pool] ERROR: Requested user '$explicit_user' quota is ${live_pct}% (floor=${MIN_REMAINING_PCT}%), exhausted until ${live_reset}." >&2
          return 1
        else
          log_usage_check "$explicit_user" "$live_pct" "$live_reset" "start"
        fi
      else
        log_usage_check "$explicit_user" "" "" "unknown"
      fi
    fi
    echo "$explicit_user"
    return 0
  fi

  local -a candidates=()
  local allowed_str
  allowed_str=$(allowed_users_for_model "$model")

  if [[ -n "$allowed_str" ]]; then
    read -r -a candidates <<<"$allowed_str"
  else
    # A model with no account rule in the models config must never be routed to
    # reserved accounts (Flash must never spill onto reserved accounts like piyushjiit).
    local -a normal=()
    for u in "${GPRO_USERS[@]}"; do
      if ! is_reserved_user "$u"; then
        normal+=("$u")
      fi
    done
    candidates=("${normal[@]}")
  fi

  for u in "${candidates[@]}"; do
    id "$u" >/dev/null 2>&1 || continue
    is_authenticated "$u" || continue
    local pct
    pct=$(get_remaining_pct "$u" "$model")
    if (( pct <= MIN_REMAINING_PCT )); then
      continue
    fi

    # Do not run /usage for Hydrogen/Neon (reserved account) spawns for now
    if is_hydrogen_or_neon "$model" || is_reserved_user "$u"; then
      echo "$u"
      return 0
    fi

    # Check live usage via `agy -p /usage` once as selected account
    local usage_info live_pct live_reset
    if usage_info=$(query_live_usage "$u"); then
      read -r live_pct live_reset <<<"$usage_info"
      if [[ -n "$live_pct" ]]; then
        if (( live_pct > MIN_REMAINING_PCT )); then
          log_usage_check "$u" "$live_pct" "$live_reset" "start"
          echo "$u"
          return 0
        else
          log_usage_check "$u" "$live_pct" "$live_reset" "skip"
          local rst_epoch
          rst_epoch=$(date -d "$live_reset" +%s 2>/dev/null || echo 0)
          (( rst_epoch <= 0 )) && rst_epoch=$(( $(now_epoch) + WINDOW_SECONDS ))
          mark_account_exhausted "$u" "$rst_epoch"
          echo "[fm-agy-pool] Account '$u' live quota is ${live_pct}% (floor=${MIN_REMAINING_PCT}%), exhausted until ${live_reset}; skipping to next account." >&2
          continue
        fi
      fi
    fi

    # If /usage output cannot be parsed or the command fails, treat as unknown:
    # start on the sticky account and rely on the quota-error path
    log_usage_check "$u" "" "" "unknown"
    echo "$u"
    return 0
  done
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

  local usage_info live_pct live_reset
  if ! usage_info=$(query_live_usage "$target" true); then
    echo "[fm-agy-pool] ERROR: Failed to query live usage for '$target'." >&2
    exit 1
  fi

  printf '%s\n' "$usage_info"
  read -r live_pct live_reset <<<"$(tail -n 1 <<<"$usage_info")"
  log_usage_check "$target" "$live_pct" "$live_reset" "manual"
  if [[ -n "$live_pct" && "$live_pct" =~ ^[0-9]+$ && "$live_pct" -le "$MIN_REMAINING_PCT" ]]; then
    local rst_epoch
    rst_epoch=$(date -d "$live_reset" +%s 2>/dev/null || echo 0)
    (( rst_epoch <= 0 )) && rst_epoch=$(( $(now_epoch) + WINDOW_SECONDS ))
    mark_account_exhausted "$target" "$rst_epoch"
  fi
  exit 0
}

cmd_status() {
  printf "%-11s %-14s %-16s %-22s %-26s %s\n" "ACCOUNT" "STATUS" "REMAINING" "RESET_AT" "CHECKED_AT" "SPECIAL_MODELS"
  for u in "${GPRO_USERS[@]}"; do
    local auth="PENDING_LOGIN"
    id "$u" >/dev/null 2>&1 || auth="MISSING_USER"
    [[ "$auth" == "PENDING_LOGIN" ]] && is_authenticated "$u" && auth="READY"

    local pct="unknown"
    local rst_str="unknown"
    local chk_ts="unknown"
    if [[ -f "$USAGE_LOG" ]]; then
      local last_entry
      last_entry=$(jq -s --arg u "$u" '[.[] | select(.user == $u and .event == "usage_check")] | last' "$USAGE_LOG" 2>/dev/null || true)
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

    local special="flash-3.8"
    if is_reserved_user "$u"; then
      special="hydrogen,neon"
    fi

    printf "%-11s %-14s %-16s %-22s %-26s %s\n" \
      "$u" "$auth" "$pct" "$rst_str" "$chk_ts" "$special"
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
  local allowed_str
  allowed_str=$(allowed_users_for_model "$model")
  if [[ -n "$allowed_str" ]]; then
    local -a candidates=()
    read -r -a candidates <<<"$allowed_str"
    for c in "${candidates[@]}"; do
      [[ "$c" == "$user" ]] && return 0
    done
    return 1
  else
    if is_reserved_user "$user"; then
      return 1
    fi
    return 0
  fi
}

is_user_exhausted() {
  local user="$1" model="${2:-}"
  local pct
  pct=$(get_remaining_pct "$user" "$model")
  (( pct <= MIN_REMAINING_PCT ))
}

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
    if [[ -n "$owner" ]] && is_user_allowed_for_model "$owner" "$ROUTE_MODEL"; then
      for u in "${GPRO_USERS[@]}"; do
        [[ "$u" == "$owner" ]] && { printf '%s\n' "$owner"; return 0; }
      done
    fi
  fi
  for u in "${GPRO_USERS[@]}"; do
    is_user_allowed_for_model "$u" "$ROUTE_MODEL" || continue
    if [[ -n "$(sudo -n -u "$u" find "$AGY_HOME_BASE/$u/.gemini/antigravity-cli/conversations" -maxdepth 1 -name "*${id}*" -print -quit 2>/dev/null)" ]]; then
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
  local active_users=() active_user picked=""
  local -a ordered=() allowed=()
  mapfile -t active_users < <(find_active_pool_users)
  read -r -a allowed <<<"$(allowed_users_for_model "$ROUTE_MODEL")"
  for active_user in ${allowed[@]+"${allowed[@]}"} ${active_users[@]+"${active_users[@]}"}; do
    case " ${active_users[*]-} " in *" $active_user "*) ;; *) continue ;; esac
    case " ${ordered[*]-} " in *" $active_user "*) continue ;; esac
    ordered+=("$active_user")
  done
  for active_user in ${ordered[@]+"${ordered[@]}"}; do
    if [[ -n "$EXPLICIT_USER" ]]; then
      [[ "$EXPLICIT_USER" == "$active_user" ]] || continue
    elif (( ${#active_users[@]} < MAX_ACTIVE )); then
      break
    fi
    is_user_allowed_for_model "$active_user" "$ROUTE_MODEL" || continue
    is_user_exhausted "$active_user" "$ROUTE_MODEL" && continue
    picked="$active_user"
    break
  done
  if [[ -z "$picked" ]]; then
    if (( ${#active_users[@]} >= MAX_ACTIVE )); then
      echo "[fm-agy-pool] ERROR: ${#active_users[@]} pool accounts already active (${active_users[*]}), none fit model '${ROUTE_MODEL:-default}'${EXPLICIT_USER:+ / account $EXPLICIT_USER}; cap is $MAX_ACTIVE (FM_AGY_MAX_ACTIVE)." >&2
      return 75
    fi
    picked=$(pick_sticky_user "$ROUTE_MODEL" "$EXPLICIT_USER" || true)
  fi
  if [[ -z "$picked" ]]; then
    return 1
  fi
  printf '%s\n' "$picked"
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
  select_rc=0
  SELECTED_USER=$(select_pool_user) || select_rc=$?
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

  BEFORE_PCT=$(get_remaining_pct "$SELECTED_USER" "$ROUTE_MODEL")
  START_TS=$(now_epoch)
  if [[ "$RUN_LOG_EPHEMERAL" -eq 1 ]]; then
    : > "$RUN_LOG"
  fi
  chmod 0644 "$RUN_LOG" 2>/dev/null || true
  RUN_LOG_OFFSET=$(wc -c < "$RUN_LOG" 2>/dev/null || echo 0)

  echo "[fm-agy-pool] Routing model '${ROUTE_MODEL:-default}' to '$SELECTED_USER' (${BEFORE_PCT}% remaining, floor=${MIN_REMAINING_PCT}%)..." >&2

  if [[ "${AGY_ARGS[0]:-}" != models ]]; then
    mirror_trust
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
