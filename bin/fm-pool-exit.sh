#!/usr/bin/env bash
# fm-pool-exit.sh <task-id> [--once]
# Frees a pool account slot (FM_AGY_MAX_ACTIVE) once a pool builder is finished:
# polls state/<task>.status and, when its latest line is `done`, stops the
# builder through the control plane (bin/fm-control.sh <task> exit), which keeps
# the worktree and every commit. Armed by bin/fm-spawn.sh for pool builds; it
# exits when the task record is gone or after 24h. --once checks a single time.
# FM_POOL_EXIT=off disables it; FM_POOL_EXIT_INTERVAL sets the poll seconds.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
TASK="${1:?usage: fm-pool-exit.sh <task-id> [--once]}"
ONCE="${2:-}"
[ "${FM_POOL_EXIT:-on}" != off ] || exit 0
CONTROL="${FM_POOL_EXIT_CONTROL:-$SCRIPT_DIR/fm-control.sh}"
interval="${FM_POOL_EXIT_INTERVAL:-15}"

is_done() {
  local last
  last=$(grep -v '^[[:space:]]*$' "$FM_STATE/$TASK.status" 2>/dev/null | tail -n 1 || true)
  case "$last" in done\ *|done:*) return 0 ;; esac
  return 1
}

for _ in $(seq $((86400 / interval))); do
  [ -e "$FM_STATE/$TASK.meta" ] || exit 0
  if is_done; then
    FM_HOME="$FM_HOME" "$CONTROL" "$TASK" exit && exit 0
    exit 1
  fi
  [ "$ONCE" != --once ] || exit 1
  sleep "$interval"
done
