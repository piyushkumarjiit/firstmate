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

# Helper to inspect gate/outcome and update status file
handle_gate_or_outcome() {
  local wt="$1" stat_file="$2" dlog="$3"
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
    fi
    return 0
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
      ;;
    failed|cancelled|blocked)
      local now
      now=$(date +%s)
      echo "blocked [at=$now]: outcome $outcome" >> "$stat_file"
      ;;
    *)
      if [[ -n "$outcome" ]]; then
        local now
        now=$(date +%s)
        echo "blocked [at=$now]: outcome $outcome" >> "$stat_file"
      fi
      ;;
  esac
}

resolve_open_gate_if_present() {
  local sfile="$1" dlog="$2"
  shift 2

  local open_gate_key
  open_gate_key=$(awk '
    /^[[:space:]]*needs-decision/ && /\[key=gate-[^]]+\]/ {
      match($0, /\[key=(gate-[^]]+)\]/, m)
      if (m[1] != "") {
        latest_key = m[1]
        resolved[latest_key] = 0
      }
    }
    /^[[:space:]]*resolved/ && /\[key=gate-[^]]+\]/ {
      match($0, /\[key=(gate-[^]]+)\]/, m)
      if (m[1] != "") {
        resolved[m[1]] = 1
      }
    }
    END {
      if (latest_key != "" && resolved[latest_key] == 0) {
        print latest_key
      }
    }
  ' "$sfile")

  [[ -z "$open_gate_key" ]] && return 0

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

  local now
  now=$(date +%s)
  echo "resolved [at=$now] [key=${open_gate_key}]: $note" >> "$sfile"
  echo "[fm-deliver] Resolved gate '${open_gate_key}': $note" >> "$dlog"
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
    for arg in "$@"; do
      if [[ "$arg" == "--yes" || "$arg" == "-y" || "$arg" =~ ^--yes= ]]; then
        echo "error: --yes is banned in fm-deliver.sh respond" >&2
        exit 1
      fi
    done

    resolve_open_gate_if_present "$STATUS_FILE" "$DRIVE_LOG" "$@"

    echo "[fm-deliver] Running respond in $WORKTREE: no-mistakes axi respond $*" >> "$DRIVE_LOG"
    ( cd "$WORKTREE" && no-mistakes axi respond "$@" ) >> "$DRIVE_LOG" 2>&1 || true
    handle_gate_or_outcome "$WORKTREE" "$STATUS_FILE" "$DRIVE_LOG"
    ;;
  run)
    if [[ "${1:-}" == "--background-worker" ]]; then
      shift
      INTENT="$1"
      shift
      echo "[fm-deliver] Starting axi run in $WORKTREE with intent: $INTENT" >> "$DRIVE_LOG"
      ( cd "$WORKTREE" && no-mistakes axi run --intent "$INTENT" "$@" ) >> "$DRIVE_LOG" 2>&1 || true
      handle_gate_or_outcome "$WORKTREE" "$STATUS_FILE" "$DRIVE_LOG"
      exit 0
    fi

    # Extract intent from brief
    BRIEF_FILE="$FM_DATA/${TASK}/brief.md"
    [[ ! -f "$BRIEF_FILE" ]] && BRIEF_FILE="$FM_DATA/${TASK}/launch-brief.md"
    INTENT=""
    if [[ -f "$BRIEF_FILE" ]]; then
      INTENT=$(fm_brief_task_heading_body "$BRIEF_FILE" "## Captain's intent" 2>/dev/null || true)
    fi
    if [[ -z "$INTENT" ]]; then
      echo "error: could not extract Captain's intent from $BRIEF_FILE" >&2
      exit 1
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

    MODE=$(grep -E '^mode=' "$META_FILE" | head -n 1 | cut -d= -f2- || true)
    RUN_EXTRA_ARGS=()
    case "$MODE" in
      local-only)
        RUN_EXTRA_ARGS+=(--skip "push,pr,ci")
        ;;
      branch-only|direct-push)
        RUN_EXTRA_ARGS+=(--skip "pr,ci")
        ;;
    esac

    BASE=$(grep -E '^base=' "$META_FILE" | head -n 1 | cut -d= -f2- || true)
    if [[ -n "$BASE" ]]; then
      RUN_EXTRA_ARGS+=(--base-branch "$BASE")
    fi

    if [[ "${FM_DELIVER_FOREGROUND:-0}" == "1" ]]; then
      echo "[fm-deliver] Running axi run in foreground..."
      ( cd "$WORKTREE" && no-mistakes axi run --intent "$INTENT" "${RUN_EXTRA_ARGS[@]}" ) >> "$DRIVE_LOG" 2>&1 || true
      handle_gate_or_outcome "$WORKTREE" "$STATUS_FILE" "$DRIVE_LOG"
    else
      "$0" "$TASK" run --background-worker "$INTENT" "${RUN_EXTRA_ARGS[@]}" </dev/null >> "$DRIVE_LOG" 2>&1 &
      BG_PID=$!
      echo "[fm-deliver] Started no-mistakes axi run in background (PID $BG_PID), logging to $DRIVE_LOG"
      open_progress_tab || true
    fi
    ;;
esac
