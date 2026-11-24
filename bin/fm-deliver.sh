#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# fm-deliver.sh
# Tracked runner with no LLM for no-mistakes validation of pool-built ships.
# Runs as the main account.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
FM_CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DISPATCH_CONFIG="$FM_CONFIG/crew-dispatch.json"
POOL_CONF="${POOL_CONF:-/etc/firstmate/gpro-pool.conf}"
MODELS_CONF="${MODELS_CONF:-/etc/firstmate/gpro-models.conf}"
AGY_STATE_DIR="${FM_AGY_STATE_DIR:-/tmp/fm-agy-pool}"

# Source shared Firstmate libraries
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-brief-heading-lib.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

usage() {
  cat <<'EOF'
Usage: bin/fm-deliver.sh <task-id> run|respond|status|sync|ready|autostart [args...]

Subcommands:
  run                Start no-mistakes axi run in background for task worktree
  ready              Exit 0 when the worker's latest report is `done: committed
                     <sha>`, HEAD is that sha, the tree is clean, and no
                     validation run exists for that head yet; exit 1 otherwise
  autostart          Start a detached poller that runs `ready` every 30s and
                     then `run` once, so delivery starts the moment the
                     builder commits, with no model in the loop.
                     Re-arm after each relaunch (fm-spawn does this for pool
                     builds); FM_DELIVER_AUTOSTART=off disables it
  respond            Send gate response (--action, --findings, --ignore, etc.)
  status             Show no-mistakes axi status for task worktree
  sync               Run no-mistakes axi sync for task worktree
EOF
  exit 1
}

if [[ $# -lt 2 ]]; then
  usage
fi

TASK="$1"
SUBCMD="$2"
shift 2

case "$SUBCMD" in
  run|respond|status|sync|ready|autostart) ;;
  *)
    echo "error: unknown subcommand '$SUBCMD'" >&2
    usage
    ;;
esac

if [[ "$SUBCMD" == autostart ]]; then
  # A detached poller (no model, no process-event registry): every 30s it runs
  # `ready`, then `run` once and exits; it also exits when the task record is
  # gone (cleanup) or after 24h. Re-arming replaces the previous poller.
  [[ "${FM_DELIVER_AUTOSTART:-on}" != off ]] || exit 0
  self="$SCRIPT_DIR/fm-deliver.sh"
  pid_file="$FM_DATA/$TASK/autostart.pid"
  mkdir -p "$FM_DATA/$TASK"
  old_pid=$(cat "$pid_file" 2>/dev/null || true)
  if [[ "$old_pid" =~ ^[0-9]+$ ]] && grep -q 'fm-deliver-autostart' "/proc/$old_pid/cmdline" 2>/dev/null; then
    kill "$old_pid" 2>/dev/null || true
  fi
  # shellcheck disable=SC2016  # positional parameters expand inside the poller
  setsid nohup bash -c 'for _ in $(seq 2880); do
      [ -e "$3" ] || exit 0
      if "$1" "$2" ready >/dev/null 2>&1; then "$1" "$2" run; exit $?; fi
      sleep 30
    done' fm-deliver-autostart "$self" "$TASK" "$FM_STATE/$TASK.meta" \
    >>"$FM_DATA/$TASK/autostart.log" 2>&1 </dev/null &
  echo "$!" > "$pid_file"
  echo "armed delivery autostart for $TASK (pid $!)"
  exit 0
fi

# 1. Main account check: must run as main account and refuse otherwise
MAIN_USER="${FM_MAIN_USER:-}"
if [[ -z "$MAIN_USER" ]]; then
  MAIN_USER=$(stat -c %U "$FM_HOME" 2>/dev/null || id -un)
fi
CURRENT_USER=$(id -un)
if [[ "$CURRENT_USER" != "$MAIN_USER" ]]; then
  echo "error: fm-deliver.sh must run as main account '$MAIN_USER', running as '$CURRENT_USER'" >&2
  exit 1
fi

# 2. Meta check: state/<task>.meta names this home's task
META_FILE="$FM_STATE/${TASK}.meta"
if [[ ! -f "$META_FILE" ]]; then
  echo "error: state file $META_FILE does not exist" >&2
  exit 1
fi

ENDPOINT_TASK=$(grep -E '^endpoint_task_id=' "$META_FILE" | head -n 1 | cut -d= -f2-)
if [[ "$ENDPOINT_TASK" != "$TASK" ]]; then
  echo "error: state/$TASK.meta endpoint_task_id '$ENDPOINT_TASK' does not match task '$TASK'" >&2
  exit 1
fi

# 3. Worktree check: recorded worktree exists
WORKTREE=$(grep -E '^worktree=' "$META_FILE" | head -n 1 | cut -d= -f2-)
if [[ -z "$WORKTREE" || ! -d "$WORKTREE" ]]; then
  echo "error: recorded worktree '$WORKTREE' does not exist" >&2
  exit 1
fi

# 4. Branch check: worktree branch matches meta
EXPECTED_BRANCH=$(grep -E '^branch=' "$META_FILE" | head -n 1 | cut -d= -f2-)
ACTUAL_BRANCH=$(git -C "$WORKTREE" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
if [[ "$ACTUAL_BRANCH" != "$EXPECTED_BRANCH" ]]; then
  echo "error: worktree branch '$ACTUAL_BRANCH' does not match meta branch '$EXPECTED_BRANCH'" >&2
  exit 1
fi

# 5. Clean tree check
STATUS_PORCELAIN=$(git -C "$WORKTREE" status --porcelain 2>/dev/null || true)
if [[ -n "$STATUS_PORCELAIN" ]]; then
  echo "error: worktree '$WORKTREE' has uncommitted changes" >&2
  exit 1
fi

# 6. HEAD equals the sha in worker's done: committed <sha> line
STATUS_FILE="$FM_STATE/${TASK}.status"
if [[ ! -f "$STATUS_FILE" ]]; then
  echo "error: status file $STATUS_FILE does not exist" >&2
  exit 1
fi

COMMITTED_SHA=$(grep -E '^[[:space:]]*done([[:space:]]+\[[^]]*\])*[[:space:]]*:[[:space:]]*committed[[:space:]]+[0-9a-fA-F]+' "$STATUS_FILE" | tail -n 1 | sed -E 's/.*committed[[:space:]]+([0-9a-fA-F]+).*/\1/' || true)
if [[ -z "$COMMITTED_SHA" ]]; then
  echo "error: no 'done: committed <sha>' found in $STATUS_FILE" >&2
  exit 1
fi

ACTUAL_SHA=$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || true)
EXPECTED_SHA=$(git -C "$WORKTREE" rev-parse "$COMMITTED_SHA" 2>/dev/null || true)

if [[ "$SUBCMD" == "run" || "$SUBCMD" == "ready" ]]; then
  if [[ -z "$EXPECTED_SHA" || "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
    echo "error: worktree HEAD '$ACTUAL_SHA' does not match worker committed SHA '$COMMITTED_SHA'" >&2
    exit 1
  fi
else
  # For respond, status, sync: HEAD must equal or descend from COMMITTED_SHA
  if ! git -C "$WORKTREE" merge-base --is-ancestor "$EXPECTED_SHA" "$ACTUAL_SHA" 2>/dev/null; then
    echo "error: worktree HEAD '$ACTUAL_SHA' is not an ancestor of or equal to committed SHA '$COMMITTED_SHA'" >&2
    exit 1
  fi
fi

if [[ "$SUBCMD" == ready ]]; then
  # The worker's latest lifecycle line must be the done report itself.
  last_state=$(grep -E '^[[:space:]]*(working|done|blocked|needs-decision|paused)([[:space:]]|\[|:)' "$STATUS_FILE" | tail -n 1 || true)
  [[ "$last_state" =~ ^[[:space:]]*done.*committed ]] || exit 1
  run_head=$(cd "$WORKTREE" && no-mistakes axi status 2>/dev/null | sed -n 's/^[[:space:]]*head_sha:[[:space:]]*"\{0,1\}\([0-9a-f]*\).*/\1/p' | head -n 1)
  [[ "$run_head" != "$ACTUAL_SHA" ]] || exit 1
  exit 0
fi

DRIVE_LOG="$FM_DATA/${TASK}/drive.log"
mkdir -p "$(dirname "$DRIVE_LOG")"

# Visible progress: delivery runs as a background job, so on a herdr-backed task
# open one "deliver: <task>" tab in the task's workspace that follows the drive
# log live. Best effort only - it never affects delivery. The tab's shell exits
# (and herdr closes the tab) once the task worktree is gone, i.e. at cleanup.
# A rerun reuses a still-open tab. FM_DELIVER_TAB=off disables it.
open_progress_tab() {
  [[ "${FM_DELIVER_TAB:-on}" != off ]] || return 0
  command -v herdr >/dev/null 2>&1 || return 0
  local backend ws tab_file pane out cmd
  backend=$(grep -E '^backend=' "$META_FILE" | head -n 1 | cut -d= -f2- || true)
  [[ "$backend" == herdr ]] || return 0
  ws=$(grep -E '^herdr_workspace_id=' "$META_FILE" | head -n 1 | cut -d= -f2- || true)
  [[ -n "$ws" ]] || return 0
  tab_file="$FM_DATA/${TASK}/deliver-tab"
  if [[ -s "$tab_file" ]]; then
    pane=$(cat "$tab_file")
    if herdr pane get "$pane" >/dev/null 2>&1; then
      return 0
    fi
  fi
  out=$(herdr tab create --workspace "$ws" --label "deliver: $TASK" --cwd "$FM_DATA/$TASK" --no-focus 2>/dev/null) || return 0
  pane=$(jq -r '.result.root_pane.pane_id // empty' <<<"$out" 2>/dev/null || true)
  [[ -n "$pane" ]] || return 0
  printf '%s\n' "$pane" > "$tab_file"
  # shellcheck disable=SC2016  # $! and $tp expand in the tab shell, not here
  printf -v cmd 'clear; echo %q; tail -n 60 -F %q & tp=$!; while [ -e %q ]; do sleep 5; done; kill $tp 2>/dev/null; exit' \
    "delivery progress for $TASK (read-only view; closes at cleanup)" "$DRIVE_LOG" "$META_FILE"
  herdr pane run "$pane" "$cmd" >/dev/null 2>&1 || true
}

# Role fallback state (loaded from config/crew-dispatch.json roles.review / roles.fix)
REVIEW_HARNESSES=()
REVIEW_MODELS=()
REVIEW_ACCOUNTS=()
REVIEW_IDX=0
FIX_HARNESSES=()
FIX_MODELS=()
FIX_ACCOUNTS=()
FIX_IDX=0

allowed_users_for_model() {
  local model="${1:-}"
  if [[ -n "$model" && -f "$MODELS_CONF" ]]; then
    local line pattern users_str
    while IFS= read -r line; do
      line="${line%%#*}"
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -z "$line" ]] && continue
      pattern=$(awk '{print $1}' <<<"$line")
      users_str=$(awk '{$1=""; sub(/^ +/,""); print}' <<<"$line")
      [[ -z "$pattern" || -z "$users_str" ]] && continue
      # shellcheck disable=SC2053
      if [[ "$model" == $pattern ]]; then
        printf '%s\n' "${users_str//,/ }"
        return 0
      fi
    done < "$MODELS_CONF"
  fi
  if [[ -f "$POOL_CONF" ]]; then
    local u reserved_list=""
    if [[ -f "$MODELS_CONF" ]]; then
      reserved_list=$(grep -Ev '^\s*(#|$)' "$MODELS_CONF" | awk '{for (i=2; i<=NF; i++) print $i}' | tr ',' '\n')
    fi
    local -a normal=()
    while IFS= read -r u; do
      [[ -n "$u" ]] || continue
      if [[ -n "$reserved_list" ]] && grep -Fxq "$u" <<<"$reserved_list"; then
        continue
      fi
      normal+=("$u")
    done < <(grep -Ev '^\s*(#|$)' "$POOL_CONF" | awk '{print $1}')
    printf '%s\n' "${normal[*]}"
  fi
}

user_is_exhausted() {
  local user="$1" qfile="$AGY_STATE_DIR/${1}.state.json"
  [[ -f "$qfile" ]] || return 1
  local exh reset_at now
  exh=$(jq -r '.exhausted // false' "$qfile" 2>/dev/null || echo false)
  [[ "$exh" == "true" ]] || return 1
  reset_at=$(jq -r '.reset_at // 0' "$qfile" 2>/dev/null || echo 0)
  now=$(date +%s)
  if (( reset_at > 0 && now >= reset_at )); then
    return 1
  fi
  return 0
}

all_accounts_exhausted_for_entry() {
  local harness="$1" model="$2" account="$3"
  [[ "$harness" == "agy" ]] || return 1
  local -a candidates=()
  if [[ -n "$account" ]]; then
    candidates=("$account")
  else
    local allowed_str
    allowed_str=$(allowed_users_for_model "$model")
    if [[ -n "$allowed_str" ]]; then
      read -r -a candidates <<<"$allowed_str"
    fi
  fi
  (( ${#candidates[@]} > 0 )) || return 1
  local u
  for u in "${candidates[@]}"; do
    if ! user_is_exhausted "$u"; then
      return 1
    fi
  done
  return 0
}

load_role_configs() {
  REVIEW_HARNESSES=(); REVIEW_MODELS=(); REVIEW_ACCOUNTS=(); REVIEW_IDX=0
  FIX_HARNESSES=(); FIX_MODELS=(); FIX_ACCOUNTS=(); FIX_IDX=0
  [[ -f "$DISPATCH_CONFIG" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local row h m a
  while IFS=$'\t' read -r h m a; do
    [[ -n "$h" && -n "$m" ]] || continue
    REVIEW_HARNESSES+=("$h")
    REVIEW_MODELS+=("$m")
    REVIEW_ACCOUNTS+=("$a")
  done < <(jq -r '(.roles.review // [])[]? | [(.harness // ""), (.model // ""), (.account // "")] | @tsv' "$DISPATCH_CONFIG" 2>/dev/null || true)

  while IFS=$'\t' read -r h m a; do
    [[ -n "$h" && -n "$m" ]] || continue
    FIX_HARNESSES+=("$h")
    FIX_MODELS+=("$m")
    FIX_ACCOUNTS+=("$a")
  done < <(jq -r '(.roles.fix // [])[]? | [(.harness // ""), (.model // ""), (.account // "")] | @tsv' "$DISPATCH_CONFIG" 2>/dev/null || true)

  local i
  for (( i = 0; i < ${#REVIEW_MODELS[@]}; i++ )); do
    if ! all_accounts_exhausted_for_entry "${REVIEW_HARNESSES[$i]}" "${REVIEW_MODELS[$i]}" "${REVIEW_ACCOUNTS[$i]}"; then
      REVIEW_IDX=$i
      break
    fi
  done
  for (( i = 0; i < ${#FIX_MODELS[@]}; i++ )); do
    if ! all_accounts_exhausted_for_entry "${FIX_HARNESSES[$i]}" "${FIX_MODELS[$i]}" "${FIX_ACCOUNTS[$i]}"; then
      FIX_IDX=$i
      break
    fi
  done
}

write_role_file() {
  local role_file="$FM_STATE/${TASK}.nm-roles"
  if (( ${#REVIEW_MODELS[@]} == 0 && ${#FIX_MODELS[@]} == 0 )); then
    rm -f "$role_file"
    return 0
  fi
  mkdir -p "$FM_STATE"
  local fb sep m
  {
    if (( ${#REVIEW_MODELS[@]} > 0 )); then
      fb=""; sep=""
      for m in "${REVIEW_MODELS[@]}"; do fb+="${sep}${m}"; sep=","; done
      printf 'review_model=%s\n' "${REVIEW_MODELS[$REVIEW_IDX]}"
      printf 'review_account=%s\n' "${REVIEW_ACCOUNTS[$REVIEW_IDX]}"
      printf 'review_from_config=1\n'
      printf 'review_fallback=%s\n' "$fb"
    fi
    if (( ${#FIX_MODELS[@]} > 0 )); then
      fb=""; sep=""
      for m in "${FIX_MODELS[@]}"; do fb+="${sep}${m}"; sep=","; done
      printf 'fix_model=%s\n' "${FIX_MODELS[$FIX_IDX]}"
      printf 'fix_account=%s\n' "${FIX_ACCOUNTS[$FIX_IDX]}"
      printf 'fix_from_config=1\n'
      printf 'fix_fallback=%s\n' "$fb"
    fi
  } > "$role_file"
}

export_role_env() {
  write_role_file
  if (( ${#REVIEW_MODELS[@]} > 0 )); then
    export FM_NM_REVIEW_MODEL="${REVIEW_MODELS[$REVIEW_IDX]}"
    export FM_NM_REVIEW_HARNESS="${REVIEW_HARNESSES[$REVIEW_IDX]}"
    export FM_NM_REVIEW_ACCOUNT="${REVIEW_ACCOUNTS[$REVIEW_IDX]}"
    export FM_NM_REVIEW_FROM_CONFIG=1
  fi
  if (( ${#FIX_MODELS[@]} > 0 )); then
    export FM_NM_FIX_MODEL="${FIX_MODELS[$FIX_IDX]}"
    export FM_NM_FIX_HARNESS="${FIX_HARNESSES[$FIX_IDX]}"
    export FM_NM_FIX_ACCOUNT="${FIX_ACCOUNTS[$FIX_IDX]}"
    export FM_NM_FIX_FROM_CONFIG=1
  fi
}

load_role_configs

QUOTA_EXHAUSTION_RE='^[[:space:]]*(\[fm-agy-pool\][[:space:]]*ERROR:.*|antigravity exited .*error=.*|antigravity reported error:.*|error:.*)?[[:space:]]*(All eligible accounts|No eligible account|Individual quota reached|RESOURCE_EXHAUSTED|429([[:space:]]|$)|rate[ -]?limit exceeded|quota exceeded|out of quota)'

is_quota_exhaustion_failure() {
  local wt="$1" status_toon="$2" dlog="$3" log_offset="$4"
  if grep -Eiq "$QUOTA_EXHAUSTION_RE" <<<"$status_toon"; then
    return 0
  fi
  local log_slice=""
  if [[ -f "$dlog" ]]; then
    log_slice=$(tail -c +"$((log_offset + 1))" "$dlog" 2>/dev/null || true)
    if [[ -n "$log_slice" ]] && grep -Eiq "$QUOTA_EXHAUSTION_RE" <<<"$log_slice"; then
      return 0
    fi
  fi
  local run_id nm_log
  run_id=$(fm_nm_field "$status_toon" id | tr -d '"'"'")
  if [[ -n "$run_id" ]]; then
    nm_log="${NM_HOME:-$HOME/.no-mistakes}/logs/$run_id/review.log"
    if [[ -f "$nm_log" ]] && tail -n 100 "$nm_log" 2>/dev/null | grep -Eiq "$QUOTA_EXHAUSTION_RE"; then
      return 0
    fi
  fi
  if (( ${#REVIEW_MODELS[@]} > 0 )) && all_accounts_exhausted_for_entry "${REVIEW_HARNESSES[$REVIEW_IDX]}" "${REVIEW_MODELS[$REVIEW_IDX]}" "${REVIEW_ACCOUNTS[$REVIEW_IDX]}"; then
    return 0
  fi
  if (( ${#FIX_MODELS[@]} > 0 )) && all_accounts_exhausted_for_entry "${FIX_HARNESSES[$FIX_IDX]}" "${FIX_MODELS[$FIX_IDX]}" "${FIX_ACCOUNTS[$FIX_IDX]}"; then
    return 0
  fi
  return 1
}

# Try advancing the exhausted role to its next fallback model.
# Sets ADV_ROLE, ADV_OLD_MODEL, ADV_NEW_MODEL and returns 0 when advanced, else 1.
# Must be called directly (not in a subshell) so REVIEW_IDX / FIX_IDX updates persist.
ADV_ROLE=""
ADV_OLD_MODEL=""
ADV_NEW_MODEL=""
advance_fallback_role() {
  local status_toon="$1" dlog="$2" log_offset="$3"
  ADV_ROLE=""; ADV_OLD_MODEL=""; ADV_NEW_MODEL=""
  local log_slice="" nm_log="" run_id="" failed_role=""
  if [[ -f "$dlog" ]]; then
    log_slice=$(tail -c +"$((log_offset + 1))" "$dlog" 2>/dev/null || true)
  fi
  run_id=$(fm_nm_field "$status_toon" id | tr -d '"'"'")
  if [[ -n "$run_id" && -f "${NM_HOME:-$HOME/.no-mistakes}/logs/$run_id/review.log" ]]; then
    nm_log=$(tail -n 100 "${NM_HOME:-$HOME/.no-mistakes}/logs/$run_id/review.log" 2>/dev/null || true)
  fi

  local review_exhausted=0 fix_exhausted=0
  if (( ${#REVIEW_MODELS[@]} > 0 )) && all_accounts_exhausted_for_entry "${REVIEW_HARNESSES[$REVIEW_IDX]}" "${REVIEW_MODELS[$REVIEW_IDX]}" "${REVIEW_ACCOUNTS[$REVIEW_IDX]}"; then
    review_exhausted=1
  fi
  if (( ${#FIX_MODELS[@]} > 0 )) && all_accounts_exhausted_for_entry "${FIX_HARNESSES[$FIX_IDX]}" "${FIX_MODELS[$FIX_IDX]}" "${FIX_ACCOUNTS[$FIX_IDX]}"; then
    fix_exhausted=1
  fi

  if (( review_exhausted == 1 && fix_exhausted == 0 )); then
    failed_role=review
  elif (( fix_exhausted == 1 && review_exhausted == 0 )); then
    failed_role=fix
  else
    local combined_log="${log_slice}"$'\n'"${nm_log}"
    local last_role
    last_role=$(grep -Eo 'role=(review|fix)' <<<"$combined_log" | tail -n 1 | cut -d= -f2 || true)
    if [[ -n "$last_role" ]]; then
      failed_role="$last_role"
    elif grep -Eiq 'fix|fix_review' <<<"$status_toon"; then
      failed_role=fix
    elif grep -Eiq 'review' <<<"$status_toon"; then
      failed_role=review
    fi
  fi

  if [[ "$failed_role" == "fix" ]]; then
    if (( FIX_IDX + 1 < ${#FIX_MODELS[@]} )); then
      ADV_ROLE="fix"
      ADV_OLD_MODEL="${FIX_MODELS[$FIX_IDX]}"
      FIX_IDX=$((FIX_IDX + 1))
      ADV_NEW_MODEL="${FIX_MODELS[$FIX_IDX]}"
      return 0
    fi
    return 1
  elif [[ "$failed_role" == "review" ]]; then
    if (( REVIEW_IDX + 1 < ${#REVIEW_MODELS[@]} )); then
      ADV_ROLE="review"
      ADV_OLD_MODEL="${REVIEW_MODELS[$REVIEW_IDX]}"
      REVIEW_IDX=$((REVIEW_IDX + 1))
      ADV_NEW_MODEL="${REVIEW_MODELS[$REVIEW_IDX]}"
      return 0
    fi
    return 1
  fi

  # Disambiguation absent (e.g. minimal stub): advance review if it has a fallback, else fix
  if (( REVIEW_IDX + 1 < ${#REVIEW_MODELS[@]} )); then
    ADV_ROLE="review"
    ADV_OLD_MODEL="${REVIEW_MODELS[$REVIEW_IDX]}"
    REVIEW_IDX=$((REVIEW_IDX + 1))
    ADV_NEW_MODEL="${REVIEW_MODELS[$REVIEW_IDX]}"
    return 0
  fi
  if (( FIX_IDX + 1 < ${#FIX_MODELS[@]} )); then
    ADV_ROLE="fix"
    ADV_OLD_MODEL="${FIX_MODELS[$FIX_IDX]}"
    FIX_IDX=$((FIX_IDX + 1))
    ADV_NEW_MODEL="${FIX_MODELS[$FIX_IDX]}"
    return 0
  fi
  return 1
}

report_herdr_gate_state() {
  local state="$1" message="${2:-}"
  command -v herdr >/dev/null 2>&1 || return 0
  local backend session pane="" agent_label=""
  backend=$(grep -E '^backend=' "$META_FILE" 2>/dev/null | head -n 1 | cut -d= -f2- || true)
  [[ "$backend" == "herdr" ]] || return 0
  session=$(grep -E '^herdr_session=' "$META_FILE" 2>/dev/null | head -n 1 | cut -d= -f2- || true)
  if [[ -n "$session" && -z "${HERDR_SESSION:-}" ]]; then
    export HERDR_SESSION="$session"
  fi
  if [[ -s "$FM_DATA/${TASK}/nm-active-tab" ]]; then
    IFS=$'\t' read -r pane agent_label < "$FM_DATA/${TASK}/nm-active-tab" || true
  elif [[ -s "$FM_DATA/${TASK}/deliver-tab" ]]; then
    pane=$(cat "$FM_DATA/${TASK}/deliver-tab" 2>/dev/null || true)
    agent_label="deliver:${TASK}"
  fi
  [[ -n "$pane" ]] || return 0
  local -a args=(pane report-agent "$pane" --source "firstmate:nm-agy" --agent "${agent_label:-deliver:$TASK}" --state "$state")
  [[ -n "$message" ]] && args+=(--message "$message")
  if command -v timeout >/dev/null 2>&1; then
    timeout 3 herdr "${args[@]}" >/dev/null 2>&1 || true
  else
    herdr "${args[@]}" >/dev/null 2>&1 || true
  fi
}

build_run_intent_and_args() {
  BRIEF_FILE="$FM_DATA/${TASK}/brief.md"
  [[ ! -f "$BRIEF_FILE" ]] && BRIEF_FILE="$FM_DATA/${TASK}/launch-brief.md"
  INTENT=""
  if [[ -f "$BRIEF_FILE" ]]; then
    INTENT=$(fm_brief_task_heading_body "$BRIEF_FILE" "## Captain's intent" 2>/dev/null || true)
  fi
  if [[ -z "$INTENT" ]]; then
    echo "error: could not extract Captain's intent from $BRIEF_FILE" >&2
    return 1
  fi

  if [[ -f "$STATUS_FILE" ]]; then
    DECISION_LINES=$(awk '
      /^resolved / && /: answered: / {
        if (match($0, /\[key=[^]]+\]/)) {
          key = substr($0, RSTART + 5, RLENGTH - 6)
          if (key !~ /^gate-/) {
            print $0
          }
        }
      }
    ' "$STATUS_FILE" 2>/dev/null || true)
    if [[ -n "$DECISION_LINES" ]]; then
      INTENT="${INTENT}"$'\n\n## Firstmate decisions\n'"${DECISION_LINES}"
    fi
  fi

  local mode base
  mode=$(grep -E '^mode=' "$META_FILE" | head -n 1 | cut -d= -f2- || true)
  RUN_EXTRA_ARGS=()
  case "$mode" in
    local-only)
      RUN_EXTRA_ARGS+=(--skip "push,pr,ci")
      ;;
    branch-only|direct-push)
      RUN_EXTRA_ARGS+=(--skip "pr,ci")
      ;;
  esac

  base=$(grep -E '^base=' "$META_FILE" | head -n 1 | cut -d= -f2- || true)
  if [[ -n "$base" ]]; then
    RUN_EXTRA_ARGS+=(--base-branch "$base")
  fi
}

# Helper to inspect gate/outcome and update status file (with quota failover restart)
handle_gate_or_outcome() {
  local wt="$1" stat_file="$2" dlog="$3" log_offset="${4:-0}"
  local failover_budget=$(( ${#REVIEW_MODELS[@]} + ${#FIX_MODELS[@]} ))
  local failovers=0

  while :; do
    local status_toon attempts=0 max_reattach="${FM_DELIVER_REATTACH_MAX:-15}"
    status_toon=$(cd "$wt" && no-mistakes axi status 2>/dev/null || true)

    # A drive call returns when its bounded hold (8m) elapses even though the run
    # keeps going ("wait of 8m0s elapsed ... not a pipeline failure"). While the
    # run is still executing or waiting for its driver, and is not at a gate,
    # reattach with `no-mistakes axi run` instead of reading an outcome.
    while ! grep -q '^gate:' <<<"$status_toon" &&
      { fm_nm_run_is_executing "$status_toon" || grep -Eq '^[[:space:]]*awaiting_agent:' <<<"$status_toon"; } &&
      (( attempts < max_reattach )); do
      attempts=$((attempts + 1))
      echo "[fm-deliver] Run still in progress; reattaching (${attempts}/${max_reattach})" >> "$dlog"
      ( cd "$wt" && no-mistakes axi run ) >> "$dlog" 2>&1 || true
      status_toon=$(cd "$wt" && no-mistakes axi status 2>/dev/null || true)
    done

    # Check if parked at gate
    if grep -q '^gate:' <<<"$status_toon"; then
      local gate_step
      gate_step=$(awk '/^gate:/{flag=1;next}/^[^ ]/{flag=0}flag && /^[[:space:]]+step:/{print $2; exit}' <<<"$status_toon")
      [[ -z "$gate_step" ]] && gate_step="gate"

      local gate_findings
      gate_findings=$(awk '
        /^gate:/{in_gate=1; next}
        /^[^ ]/{in_gate=0}
        in_gate && /^[[:space:]]+summary:/{
          sub(/^[[:space:]]+summary:[[:space:]]*/, "")
          summary=$0
        }
        in_gate && /^[[:space:]]+findings\[/{
          in_findings=1; next
        }
        in_findings && /^[[:space:]]+[a-zA-Z0-9_-]+,/{
          match($0, /^[[:space:]]+([a-zA-Z0-9_-]+)/, m)
          if (m[1] != "") {
            if (fids != "") fids = fids ", " m[1]
            else fids = m[1]
          }
        }
        END {
          if (fids != "") print fids
          else if (summary != "") print summary
          else print "unspecified findings"
        }
      ' <<<"$status_toon")

      local now
      now=$(date +%s)
      echo "needs-decision [at=$now] [key=gate-${gate_step}]: ${gate_findings}" >> "$stat_file"
      echo "[fm-deliver] Parked at gate '${gate_step}', appended needs-decision to $stat_file" >> "$dlog"
      report_herdr_gate_state blocked "waiting on firstmate approval" || true
      return 0
    fi

    # Check outcome
    local outcome
    outcome=$(fm_nm_field "$status_toon" outcome)
    outcome=$(echo "$outcome" | tr -d '"'"'")

    # The current run's own status is the only outcome source: an older run's
    # "outcome:" line in the shared drive log must never be read as this run's.
    if [[ -z "$outcome" ]]; then
      if fm_nm_run_is_executing "$status_toon"; then
        local now
        now=$(date +%s)
        echo "blocked [at=$now]: delivery run still in progress after ${attempts} reattaches; check bin/fm-deliver.sh $TASK status" >> "$stat_file"
        return 0
      fi
    fi

    case "$outcome" in
      passed|passed-with-skips|passed-with-override)
        local sync_cmd
        sync_cmd=$(awk '
          /next_action:/{in_na=1; next}
          in_na && /command:/{
            sub(/.*command:[[:space:]]*/, "")
            print
            exit
          }
        ' <<<"$status_toon")
        sync_cmd=$(echo "$sync_cmd" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//')

        if [[ -z "$sync_cmd" ]]; then
          sync_cmd="no-mistakes axi sync"
        fi

        local -a sync_argv=()
        case "$sync_cmd" in
          "no-mistakes axi sync")
            sync_argv=(no-mistakes axi sync)
            ;;
          "no-mistakes axi sync --recover")
            sync_argv=(no-mistakes axi sync --recover)
            ;;
          "no-mistakes axi sync --recover --keep-local")
            sync_argv=(no-mistakes axi sync --recover --keep-local)
            ;;
          "no-mistakes axi sync --adopt-published")
            sync_argv=(no-mistakes axi sync --adopt-published)
            ;;
          *)
            local now
            now=$(date +%s)
            echo "blocked [at=$now]: unexpected sync action $sync_cmd" >> "$stat_file"
            echo "[fm-deliver] Unexpected sync command '$sync_cmd'; blocked" >> "$dlog"
            return 0
            ;;
        esac

        echo "[fm-deliver] Outcome '$outcome'; running sync command: ${sync_argv[*]}" >> "$dlog"
        ( cd "$wt" && "${sync_argv[@]}" ) >> "$dlog" 2>&1 || true

        local final_head pr_url
        # The run's own published head is authoritative; the local branch can
        # lag it when sync reads an older run's custody record.
        final_head=$(fm_nm_field "$status_toon" head_sha | tr -d '"'"'")
        [[ -n "$final_head" ]] || final_head=$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)
        pr_url=$(fm_nm_field "$status_toon" pr)
        pr_url=$(echo "$pr_url" | tr -d '"'"'")

        local now
        now=$(date +%s)
        if [[ -n "$pr_url" && "$pr_url" != "null" && "$pr_url" != '""' ]]; then
          echo "done [at=$now]: head $final_head PR $pr_url" >> "$stat_file"
        else
          echo "done [at=$now]: pushed $final_head" >> "$stat_file"
        fi
        return 0
        ;;
    esac

    # If failed (or non-executing empty outcome after quota error), check quota failover
    if (( failovers < failover_budget )) && is_quota_exhaustion_failure "$wt" "$status_toon" "$dlog" "$log_offset"; then
      if advance_fallback_role "$status_toon" "$dlog" "$log_offset"; then
        local adv_role="$ADV_ROLE" adv_old="$ADV_OLD_MODEL" adv_new="$ADV_NEW_MODEL"
        failovers=$((failovers + 1))
        local now
        now=$(date +%s)
        echo "[fm-deliver] Quota exhausted for $adv_role model '$adv_old'; restarting on same head with fallback '$adv_new'" >> "$dlog"
        echo "working [at=$now]: $adv_role model $adv_old exhausted; failing over to $adv_new" >> "$stat_file"

        ( cd "$wt" && no-mistakes axi abort ) >> "$dlog" 2>&1 || true
        local rec_status rec_state
        rec_status=$(cd "$wt" && no-mistakes axi status 2>/dev/null || true)
        rec_state=$(fm_nm_branch_sync_state "$rec_status")
        if [[ "$rec_state" == "pipeline_owned" ]] || grep -q 'no-mistakes axi sync --recover' <<<"$rec_status"; then
          ( cd "$wt" && no-mistakes axi sync --recover ) >> "$dlog" 2>&1 || true
        fi

        if [[ -z "${INTENT:-}" ]]; then
          build_run_intent_and_args || return 0
        fi
        export_role_env
        log_offset=$(wc -c < "$dlog" 2>/dev/null || echo 0)
        echo "[fm-deliver] Restarting axi run in $wt with ${adv_role}=$adv_new" >> "$dlog"
        ( cd "$wt" && no-mistakes axi run --intent "$INTENT" "${RUN_EXTRA_ARGS[@]}" ) >> "$dlog" 2>&1 || true
        continue
      fi
    fi

    if [[ -n "$outcome" ]]; then
      local now
      now=$(date +%s)
      echo "blocked [at=$now]: outcome $outcome" >> "$stat_file"
    fi
    return 0
  done
}

NORM_ARGS=()
normalize_respond_args() {
  NORM_ARGS=()
  if [[ $# -eq 0 ]]; then
    echo "error: fm-deliver.sh respond requires an action (approve, fix, or skip)" >&2
    return 1
  fi

  local -a tokens=()
  local a
  for a in "$@"; do
    if [[ "$a" == "--yes" || "$a" == "-y" || "$a" =~ ^--yes= ]]; then
      echo "error: --yes is banned in fm-deliver.sh respond" >&2
      return 1
    fi
  done

  if [[ $# -eq 1 && "$1" == *[[:space:]]* ]]; then
    if command -v python3 >/dev/null 2>&1; then
      while IFS= read -r -d '' a; do
        tokens+=("$a")
      done < <(python3 -c '
import shlex, sys
s = sys.argv[1]
try:
    parts = shlex.split(s)
except ValueError:
    parts = s.split()
for p in parts:
    sys.stdout.write(p + "\0")
' "$1")
    else
      read -r -a tokens <<<"$1"
    fi
  else
    tokens=("$@")
  fi

  (( ${#tokens[@]} > 0 )) || {
    echo "error: fm-deliver.sh respond requires an action (approve, fix, or skip)" >&2
    return 1
  }

  for a in "${tokens[@]}"; do
    if [[ "$a" == "--yes" || "$a" == "-y" || "$a" =~ ^--yes= ]]; then
      echo "error: --yes is banned in fm-deliver.sh respond" >&2
      return 1
    fi
  done

  if [[ "${tokens[0]}" == -* ]]; then
    local has_action="" prev_flag=""
    for a in "${tokens[@]}"; do
      case "$prev_flag" in
        --action)
          has_action="$a"
          prev_flag=""
          ;;
        *)
          case "$a" in
            --action=*) has_action="${a#*=}" ;;
            --action) prev_flag="--action" ;;
          esac
          ;;
      esac
    done
    case "$has_action" in
      approve|fix|skip) ;;
      *)
        echo "error: fm-deliver.sh respond requires --action approve|fix|skip" >&2
        return 1
        ;;
    esac
    NORM_ARGS=("${tokens[@]}")
    return 0
  fi

  local action="" findings="" ignore="" instructions="" reason="" step="" run_id="" wait_dur="" add_finding=""
  local i=0 tok key val clean_tok
  while (( i < ${#tokens[@]} )); do
    tok="${tokens[$i]}"
    clean_tok="${tok%;}"
    clean_tok="${clean_tok%,}"
    clean_tok="${clean_tok%:}"
    case "${clean_tok,,}" in
      approve|fix|skip)
        if [[ -n "$action" && "$action" != "${clean_tok,,}" ]]; then
          echo "error: conflicting actions in fm-deliver.sh respond ('$action' vs '${clean_tok,,}')" >&2
          return 1
        fi
        action="${clean_tok,,}"
        i=$((i + 1))
        continue
        ;;
      yes)
        echo "error: --yes is banned in fm-deliver.sh respond" >&2
        return 1
        ;;
    esac
    if [[ "$tok" == *=* ]]; then
      key="${tok%%=*}"
      val="${tok#*=}"
      val="${val%;}"
      case "${key,,}" in
        action)
          val="${val,,}"
          val="${val%,}"
          action="$val"
          ;;
        findings)
          while [[ "$val" == *, ]] && (( i + 1 < ${#tokens[@]} )) && [[ "${tokens[$((i + 1))]}" != *=* ]]; do
            i=$((i + 1))
            val="${val}${tokens[$i]%;}"
          done
          val="${val%,}"
          findings="${findings:+$findings,}$val"
          ;;
        ignore)
          while [[ "$val" == *, ]] && (( i + 1 < ${#tokens[@]} )) && [[ "${tokens[$((i + 1))]}" != *=* ]]; do
            i=$((i + 1))
            val="${val}${tokens[$i]%;}"
          done
          val="${val%,}"
          ignore="${ignore:+$ignore,}$val"
          ;;
        instructions)
          while (( i + 1 < ${#tokens[@]} )) && [[ "${tokens[$((i + 1))]}" != *=* ]]; do
            i=$((i + 1))
            val="${val} ${tokens[$i]}"
          done
          instructions="${val%;}"
          ;;
        reason)
          while (( i + 1 < ${#tokens[@]} )) && [[ "${tokens[$((i + 1))]}" != *=* ]]; do
            i=$((i + 1))
            val="${val} ${tokens[$i]}"
          done
          reason="${val%;}"
          ;;
        step) step="${val%;}" ;;
        run) run_id="${val%;}" ;;
        wait) wait_dur="${val%;}" ;;
        add-finding|add_finding) add_finding="${val%;}" ;;
        yes)
          echo "error: --yes is banned in fm-deliver.sh respond" >&2
          return 1
          ;;
        *)
          echo "error: unrecognized respond field '$key'" >&2
          return 1
          ;;
      esac
      i=$((i + 1))
      continue
    fi
    echo "error: unrecognized respond argument '$tok'" >&2
    return 1
  done

  case "$action" in
    approve|fix|skip) ;;
    *)
      echo "error: fm-deliver.sh respond requires action approve, fix, or skip" >&2
      return 1
      ;;
  esac

  NORM_ARGS=(--action "$action")
  [[ -n "$findings" ]] && NORM_ARGS+=(--findings "$findings")
  [[ -n "$ignore" ]] && NORM_ARGS+=(--ignore "$ignore")
  [[ -n "$instructions" ]] && NORM_ARGS+=(--instructions "$instructions")
  [[ -n "$reason" ]] && NORM_ARGS+=(--reason "$reason")
  [[ -n "$step" ]] && NORM_ARGS+=(--step "$step")
  [[ -n "$run_id" ]] && NORM_ARGS+=(--run "$run_id")
  [[ -n "$wait_dur" ]] && NORM_ARGS+=(--wait "$wait_dur")
  [[ -n "$add_finding" ]] && NORM_ARGS+=(--add-finding "$add_finding")
  return 0
}

open_gate_keys() {
  local sfile="$1"
  awk -v target_keys="${FM_DELIVER_GATE_KEYS:-}" '
    BEGIN {
      n = split(target_keys, tarr, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        if (tarr[i] != "") want[tarr[i]] = 1
      }
      has_want = (target_keys != "")
    }
    /^[[:space:]]*needs-decision/ && /\[key=gate-[^]]+\]/ {
      match($0, /\[key=(gate-[^]]+)\]/, m)
      if (m[1] != "") {
        latest_key = m[1]
        resolved[m[1]] = 0
        if (!(m[1] in seen)) {
          seen[m[1]] = 1
          names[++count] = m[1]
        }
      }
    }
    /^[[:space:]]*resolved/ && /\[key=gate-[^]]+\]/ {
      match($0, /\[key=(gate-[^]]+)\]/, m)
      if (m[1] != "") {
        resolved[m[1]] = 1
      }
    }
    END {
      if (has_want) {
        for (i = 1; i <= count; i++) {
          k = names[i]
          if (want[k] && resolved[k] == 0) print k
        }
      } else if (latest_key != "" && resolved[latest_key] == 0) {
        print latest_key
      }
    }
  ' "$sfile"
}

resolve_open_gate_if_present() {
  local sfile="$1" dlog="$2"
  shift 2

  local open_gate_key_list="" k
  open_gate_key_list=$(open_gate_keys "$sfile")
  [[ -n "$open_gate_key_list" ]] || return 0

  local action="" findings="" ignore="" prev=""
  for arg in "$@"; do
    case "$prev" in
      --action) action="$arg"; prev="" ;;
      --findings) findings="$arg"; prev="" ;;
      --ignore) ignore="$arg"; prev="" ;;
      *)
        case "$arg" in
          --action=*) action="${arg#*=}" ;;
          --findings=*) findings="${arg#*=}" ;;
          --ignore=*) ignore="${arg#*=}" ;;
          --action|--findings|--ignore) prev="$arg" ;;
        esac
        ;;
    esac
  done

  local details=""
  if [[ -n "$findings" && -n "$ignore" ]]; then
    details="findings=$findings ignore=$ignore"
  elif [[ -n "$findings" ]]; then
    details="findings=$findings"
  elif [[ -n "$ignore" ]]; then
    details="ignore=$ignore"
  fi

  local note="firstmate responded ${action:-action}"
  if [[ -n "$details" ]]; then
    note="$note $details"
  fi

  local now resolved_line
  local -a resolved_lines=()
  now=$(date +%s)
  for k in $open_gate_key_list; do
    resolved_line="resolved [at=$now] [key=${k}]: $note"
    resolved_lines+=("$resolved_line")
  done
  if [[ "${FM_DELIVER_SELF_ANNOUNCED:-0}" == "1" && -r "$SCRIPT_DIR/fm-wake-lib.sh" ]]; then
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/fm-classify-lib.sh"
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    local app_rc=0
    fm_wake_status_append_self_announced "$FM_STATE" "$sfile" ${resolved_lines[@]+"${resolved_lines[@]}"} || app_rc=$?
    if [[ "$app_rc" -eq 2 ]]; then
      echo "error: could not append resolved lines to $sfile" >&2
      return 1
    fi
  else
    printf '%s\n' ${resolved_lines[@]+"${resolved_lines[@]}"} >> "$sfile"
  fi
  for k in $open_gate_key_list; do
    echo "[fm-deliver] Resolved gate '${k}': $note" >> "$dlog"
  done
}

case "$SUBCMD" in
  status)
    ( cd "$WORKTREE" && no-mistakes axi status "$@" )
    exit $?
    ;;
  sync)
    ( cd "$WORKTREE" && no-mistakes axi sync "$@" )
    exit $?
    ;;
  respond)
    normalize_respond_args "$@"

    export_role_env
    LOG_OFFSET=$(wc -c < "$DRIVE_LOG" 2>/dev/null || echo 0)
    echo "[fm-deliver] Running respond in $WORKTREE: no-mistakes axi respond ${NORM_ARGS[*]}" >> "$DRIVE_LOG"
    respond_rc=0
    ( cd "$WORKTREE" && no-mistakes axi respond "${NORM_ARGS[@]}" ) >> "$DRIVE_LOG" 2>&1 || respond_rc=$?
    if [[ "$respond_rc" -ne 0 ]]; then
      echo "[fm-deliver] respond failed (exit $respond_rc); leaving the gate open" >> "$DRIVE_LOG"
      exit "$respond_rc"
    fi
    resolve_rc=0
    resolve_open_gate_if_present "$STATUS_FILE" "$DRIVE_LOG" "${NORM_ARGS[@]}" || resolve_rc=$?
    handle_gate_or_outcome "$WORKTREE" "$STATUS_FILE" "$DRIVE_LOG" "$LOG_OFFSET"
    exit "$resolve_rc"
    ;;
  run)
    if [[ "${1:-}" == "--background-worker" ]]; then
      shift
      INTENT="$1"
      shift
      export_role_env
      LOG_OFFSET=$(wc -c < "$DRIVE_LOG" 2>/dev/null || echo 0)
      echo "[fm-deliver] Starting axi run in $WORKTREE with intent: $INTENT" >> "$DRIVE_LOG"
      ( cd "$WORKTREE" && no-mistakes axi run --intent "$INTENT" "$@" ) >> "$DRIVE_LOG" 2>&1 || true
      handle_gate_or_outcome "$WORKTREE" "$STATUS_FILE" "$DRIVE_LOG" "$LOG_OFFSET"
      exit 0
    fi

    build_run_intent_and_args

    if [[ "${FM_DELIVER_FOREGROUND:-0}" == "1" ]]; then
      export_role_env
      LOG_OFFSET=$(wc -c < "$DRIVE_LOG" 2>/dev/null || echo 0)
      echo "[fm-deliver] Running axi run in foreground..."
      ( cd "$WORKTREE" && no-mistakes axi run --intent "$INTENT" "${RUN_EXTRA_ARGS[@]}" ) >> "$DRIVE_LOG" 2>&1 || true
      handle_gate_or_outcome "$WORKTREE" "$STATUS_FILE" "$DRIVE_LOG" "$LOG_OFFSET"
    else
      "$0" "$TASK" run --background-worker "$INTENT" "${RUN_EXTRA_ARGS[@]}" </dev/null >> "$DRIVE_LOG" 2>&1 &
      BG_PID=$!
      echo "[fm-deliver] Started no-mistakes axi run in background (PID $BG_PID), logging to $DRIVE_LOG"
      open_progress_tab || true
    fi
    ;;
esac
