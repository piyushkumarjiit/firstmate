#!/usr/bin/env bash
# Live validation driver for the deliver-tab teardown change (round 2).
# Builds a throwaway FM_HOME fixture plus real herdr lab panes, then runs the
# real bin/fm-teardown.sh and reports the herdr state afterwards.
#
# Usage: WT_ROOT=... LAB=... SESSION=... SCENARIO=present|stale|duplicate|neighbour
#        [TEARDOWN_SCRIPT=...] driver.sh
set -u

WT_ROOT=${WT_ROOT:?}
LAB=${LAB:?}
SESSION=${SESSION:?}
SCENARIO=${SCENARIO:?}
TEARDOWN=${TEARDOWN_SCRIPT:-$WT_ROOT/bin/fm-teardown.sh}
CHURN=${CHURN:-0}

runh() { "$WT_ROOT/bin/fm-herdr-lab.sh" run "$SESSION" "$@"; }
step() { printf '### %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

rm -rf "$LAB/fx" "$LAB/state" "$LAB/data" "$LAB/config" "$LAB/fakebin"
mkdir -p "$LAB/state" "$LAB/data" "$LAB/config" "$LAB/fakebin" "$LAB/fx"

step "build fixture repos"
git init -q --bare "$LAB/fx/origin.git"
git -C "$LAB/fx/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$LAB/fx/origin.git" "$LAB/fx/_seed" 2>/dev/null
git -C "$LAB/fx/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "origin baseline"
git -C "$LAB/fx/_seed" push -q origin main
rm -rf "$LAB/fx/_seed"
git clone -q "$LAB/fx/origin.git" "$LAB/fx/project"
git -C "$LAB/fx/project" remote set-head origin main 2>/dev/null || true
git -C "$LAB/fx/project" worktree add -q -b fm/task-x1 "$LAB/fx/wt" main
touch "$LAB/state/.last-watcher-beat"

step "install hermetic stubs"
cat > "$LAB/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$LAB/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$LAB/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
cat > "$LAB/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
cat > "$LAB/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      '') exit 0 ;;
      status) exit 0 ;;
      abort) exit 0 ;;
    esac ;;
  runs) exit 0 ;;
esac
exit 0
SH
chmod +x "$LAB"/fakebin/*

step "clear leftover lab panes"
for p in $(runh pane list | jq -r '.result.panes[]?.pane_id'); do runh pane close "$p" >/dev/null 2>&1 || true; done
for w in $(runh workspace list | jq -r '.result.workspaces[]?.workspace_id'); do runh workspace close "$w" >/dev/null 2>&1 || true; done

step "create herdr layout: $SCENARIO"
parent=$(runh workspace create --label firstmate --no-focus --cwd "$WT_ROOT")
parent_ws=$(jq -r '.result.workspace.workspace_id' <<<"$parent")

token="liveDeliverTabToken001"
ws_label="└ task-x1 · p:$token"
if [ "${LAYOUT:-projection}" = flat ]; then
  task_ws=$parent_ws
  child=$(runh tab create --workspace "$parent_ws" --label "fm-task-x1" --no-focus --cwd "$WT_ROOT")
  task_tab=$(jq -r '.result.tab.tab_id' <<<"$child")
  task_pane=$(runh pane list | jq -r --arg t "$task_tab" '.result.panes[]|select(.tab_id==$t)|.pane_id' | head -n1)
  [ -n "$task_pane" ] || fail "flat layout could not resolve the task pane"
else
  child=$(runh workspace create --label "$ws_label" --no-focus --cwd "$WT_ROOT")
  task_ws=$(jq -r '.result.workspace.workspace_id' <<<"$child")
  task_pane=$(jq -r '.result.root_pane.pane_id' <<<"$child")
  task_tab=$(jq -r '.result.tab.tab_id' <<<"$child")
fi
{
  printf 'version=2\n'
  printf 'task_id=task-x1\n'
  printf 'projection_id=%s\n' "$token"
  printf 'home=%s\n' "$LAB"
  printf 'session=%s\n' "$SESSION"
  printf 'workspace_id=%s\n' "$task_ws"
  printf 'tab_id=%s\n' "$task_tab"
  printf 'pane_id=%s\n' "$task_pane"
  printf 'parent_workspace_id=%s\n' "$parent_ws"
  printf 'parent_label=firstmate\n'
  printf 'workspace_label=%s\n' "$ws_label"
  printf 'task_label=fm-task-x1\n'
} > "$LAB/state/task-x1.herdr-presentation"

deliver_pane=
if [ "$SCENARIO" = duplicate ]; then
  deliver_pane=$task_pane
else
  deliver_pane=$(runh tab create --workspace "$task_ws" --label "deliver: task-x1" --no-focus --cwd "$LAB" | jq -r '.result.root_pane.pane_id')
fi
mkdir -p "$LAB/data/task-x1"
printf '%s\n' "$deliver_pane" > "$LAB/data/task-x1/deliver-tab"
if [ "$SCENARIO" = stale ]; then
  step "close the deliver pane before teardown so the record is stale"
  runh pane close "$deliver_pane" >/dev/null || fail "could not pre-close the deliver pane"
  sleep 0.3
fi

neighbour_ws= ; neighbour_pane=
if [ "$SCENARIO" = neighbour ]; then
  step "create a neighbouring task's deliver tab that must survive"
  nb=$(runh workspace create --label '└ task-y1 · p:neighbourTaskToken01' --no-focus --cwd "$WT_ROOT")
  neighbour_ws=$(jq -r '.result.workspace.workspace_id' <<<"$nb")
  neighbour_pane=$(runh tab create --workspace "$neighbour_ws" --label 'deliver: task-y1' --no-focus --cwd "$LAB" | jq -r '.result.root_pane.pane_id')
  mkdir -p "$LAB/data/task-y1"
  printf '%s\n' "$neighbour_pane" > "$LAB/data/task-y1/deliver-tab"
fi

step "spawn a matching fm-deliver.sh driver process for task-x1"
cat > "$LAB/fakebin/fm-deliver.sh" <<'SH'
#!/usr/bin/env bash
sleep 300
SH
chmod +x "$LAB/fakebin/fm-deliver.sh"
env -u NO_MISTAKES_GATE "$LAB/fakebin/fm-deliver.sh" task-x1 run >/dev/null 2>&1 &
driver_pid=$!
"$LAB/fakebin/fm-deliver.sh" task-y1 run >/dev/null 2>&1 &
neighbour_driver_pid=$!
sleep 0.2
kill -0 "$driver_pid" 2>/dev/null || fail "fixture driver process did not start"

step "write metadata"
printf 'window=%s:%s\n' "$SESSION" "$task_pane" > "$LAB/state/task-x1.meta"
{
  printf 'endpoint_task_id=task-x1\n'
  printf 'worktree=%s\n' "$LAB/fx/wt"
  printf 'project=%s\n' "$LAB/fx/project"
  printf 'kind=ship\n'
  printf 'mode=local-only\n'
  printf 'spawn_gen=live-deliver-tab\n'
  printf 'backend=herdr\n'
  printf 'herdr_session=%s\n' "$SESSION"
  printf 'herdr_workspace_id=%s\n' "$task_ws"
  printf 'herdr_tab_id=%s\n' "$task_tab"
  printf 'herdr_pane_id=%s\n' "$task_pane"
} >> "$LAB/state/task-x1.meta"

step "before: herdr state"
runh workspace list | jq -c '.result.workspaces[]|{workspace_id,label,tab_count,pane_count}'
runh pane list | jq -c '.result.panes[]|{pane_id,tab_id,workspace_id}'

churn_pid=
if [ "$CHURN" = 1 ]; then
  step "start /proc pid churn so pids vanish during teardown's driver scan"
  rm -f "$LAB/churn.stop"
  (
    while [ ! -e "$LAB/churn.stop" ]; do
      for _ in 1 2 3 4 5 6 7 8; do sleep 0.01 & done
      wait
    done
  ) >/dev/null 2>&1 &
  churn_pid=$!
  sleep 0.5
fi

step "run teardown: $TEARDOWN"
bypass_arg=(-u FM_GATE_REFUSE_BYPASS)
[ "${BYPASS_GATE:-0}" = 1 ] && bypass_arg=(FM_GATE_REFUSE_BYPASS=1)
env "${bypass_arg[@]}" \
  FM_HOME="$LAB" \
  FM_ROOT_OVERRIDE="$WT_ROOT" \
  FM_STATE_OVERRIDE="$LAB/state" \
  FM_CONFIG_OVERRIDE="$LAB/config" \
  PATH="$LAB/fakebin:$PATH" \
  TERM=dumb \
  bash "$TEARDOWN" task-x1 --force > "$LAB/teardown.out" 2> "$LAB/teardown.err"
rc=$?
if [ -n "$churn_pid" ]; then
  : > "$LAB/churn.stop"
  wait "$churn_pid" 2>/dev/null || true
fi
printf 'teardown exit=%s\n' "$rc"
printf '%s\n' '--- stdout:'; cat "$LAB/teardown.out"
printf '%s\n' '--- stderr:'; cat "$LAB/teardown.err"
noise=$(grep -c 'No such file or directory' "$LAB/teardown.err" || true)
printf 'stderr-ENOENT-lines=%s\n' "$noise"

step "check the task's deliver driver process was stopped"
if kill -0 "$driver_pid" 2>/dev/null; then driver_alive=yes; else driver_alive=no; fi
printf 'task-x1 driver alive=%s\n' "$driver_alive"
kill "$neighbour_driver_pid" 2>/dev/null || true
wait "$neighbour_driver_pid" 2>/dev/null || true

step "after: herdr state"
runh workspace list | jq -c '.result.workspaces[]|{workspace_id,label,tab_count,pane_count}' | tee "$LAB/after-workspaces.txt"
runh pane list | jq -c '.result.panes[]|{pane_id,tab_id,workspace_id}' | tee "$LAB/after-panes.txt"

step "assertions"
[ "$rc" = 0 ] || fail "teardown exit was $rc"
[ "$noise" = 0 ] || fail "teardown stderr carried $noise vanished-cmdline read errors"
[ "$driver_alive" = no ] || fail "task-x1 deliver driver process survived teardown"
if [ "${LAYOUT:-projection}" = flat ]; then
  if grep -q "fm-task-x1" "$LAB/after-panes.txt"; then
    fail "task-x1 tab/pane is still present after teardown"
  fi
else
  if grep -q "$task_ws" "$LAB/after-workspaces.txt" || grep -q "task-x1" "$LAB/after-workspaces.txt"; then
    fail "task-x1 herdr workspace is still present after teardown"
  fi
fi
if grep -q "$deliver_pane" "$LAB/after-panes.txt"; then
  fail "deliver pane $deliver_pane is still present after teardown"
fi
if [ "$SCENARIO" = neighbour ]; then
  grep -q "$neighbour_ws" "$LAB/after-workspaces.txt" || fail "neighbour workspace was vandalised by task-x1 teardown"
  grep -q "$neighbour_pane" "$LAB/after-panes.txt" || fail "neighbour deliver pane was closed by task-x1 teardown"
fi
if grep -q 'warning: herdr session presentation lock path is unavailable' "$LAB/teardown.err"; then
  fail "teardown warned about a missing presentation lock"
fi
printf 'PASS scenario=%s noise=%s rc=%s\n' "$SCENARIO" "$noise" "$rc"
