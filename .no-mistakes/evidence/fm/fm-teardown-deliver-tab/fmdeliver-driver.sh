#!/usr/bin/env bash
# Disposable live-validation driver for the deliver-tab teardown change.
# Builds a throwaway fixture home + real herdr lab panes, runs the real
# bin/fm-teardown.sh, and reports the herdr workspace/pane state afterwards.
set -u

WT_ROOT=${WT_ROOT:?}
LAB=${LAB:?}
SESSION=${SESSION:?}
SCENARIO=${SCENARIO:?}          # projection|flat
DELIVER=${DELIVER:-present}     # present|stale|neighbour|duplicate
TEARDOWN=${TEARDOWN_SCRIPT:-$WT_ROOT/bin/fm-teardown.sh}
CODE_ROOT=${CODE_ROOT:-$WT_ROOT}

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

step "create herdr $SCENARIO layout"
parent=$(runh workspace create --label firstmate --no-focus --cwd "$WT_ROOT")
parent_ws=$(jq -r '.result.workspace.workspace_id' <<<"$parent")
parent_pane=$(jq -r '.result.root_pane.pane_id' <<<"$parent")

if [ "$SCENARIO" = projection ]; then
  token="liveDeliverTabToken001"   # 22 chars, [A-Za-z0-9_-]
  ws_label="└ task-x1 · p:$token"
  child=$(runh workspace create --label "$ws_label" --no-focus --cwd "$WT_ROOT")
  task_ws=$(jq -r '.result.workspace.workspace_id' <<<"$child")
  task_pane=$(jq -r '.result.root_pane.pane_id' <<<"$child")
  task_tab=$(jq -r '.result.tab.tab_id' <<<"$child")
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
else
  task_ws=$parent_ws
  task_tab=$(runh tab create --workspace "$parent_ws" --label "fm-task-x1" --no-focus --cwd "$WT_ROOT" | jq -r '.result.tab.tab_id')
  task_pane=$(runh pane list | jq -r --arg t "$task_tab" '.result.panes[]|select(.tab_id==$t)|.pane_id' | head -n1)
fi

deliver_pane=
if [ "$DELIVER" != stale ] && [ "$DELIVER" != duplicate ]; then
  deliver_pane=$(runh tab create --workspace "$task_ws" --label "deliver: task-x1" --no-focus --cwd "$LAB" | jq -r '.result.root_pane.pane_id')
fi
[ "$DELIVER" = duplicate ] && deliver_pane=$task_pane
if [ -n "$deliver_pane" ]; then mkdir -p "$LAB/data/task-x1"; printf '%s\n' "$deliver_pane" > "$LAB/data/task-x1/deliver-tab"; fi

if [ "$DELIVER" = neighbour ]; then
  step "create a neighbouring task's deliver tab that must survive"
  nb=$(runh workspace create --label '└ task-y1 · p:neighbourTaskToken01' --no-focus --cwd "$WT_ROOT")
  nb_ws=$(jq -r '.result.workspace.workspace_id' <<<"$nb")
  runh tab create --workspace "$nb_ws" --label 'deliver: task-y1' --no-focus --cwd "$LAB" \
    | jq -r '.result.root_pane.pane_id' | tee "$LAB/neighbour-deliver-pane.txt"
  mkdir -p "$LAB/data/task-y1"; cp "$LAB/neighbour-deliver-pane.txt" "$LAB/data/task-y1/deliver-tab"
fi

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

step "run teardown: $TEARDOWN"
env -u FM_GATE_REFUSE_BYPASS \
  FM_HOME="$LAB" \
  FM_ROOT_OVERRIDE="$CODE_ROOT" \
  FM_STATE_OVERRIDE="$LAB/state" \
  FM_CONFIG_OVERRIDE="$LAB/config" \
  PATH="$LAB/fakebin:$PATH" \
  TERM=dumb \
  bash "$TEARDOWN" task-x1 --force > "$LAB/teardown.out" 2> "$LAB/teardown.err"
rc=$?
printf 'teardown exit=%s\n' "$rc"
printf '%s\n' '--- stdout:'; cat "$LAB/teardown.out"
printf '%s\n' '--- stderr:'; cat "$LAB/teardown.err"

step "after: herdr state"
runh workspace list | jq -c '.result.workspaces[]|{workspace_id,label,tab_count,pane_count}' | tee "$LAB/after-workspaces.txt"
runh pane list | jq -c '.result.panes[]|{pane_id,tab_id,workspace_id}' | tee "$LAB/after-panes.txt"
