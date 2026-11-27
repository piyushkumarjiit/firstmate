#!/usr/bin/env bash
# Live validation for "Pool viewer tabs fail to close at cleanup".
#
# Drives the REAL bin/fm-teardown.sh against a REAL Herdr lab session (never the
# default/fleet session) with panes created by the real herdr CLI. The viewer
# panes are recorded exactly the way bin/agy-pool/nm-agy records them
# (data/<task>/nm-<role>-tab = pane<TAB>tab-id) and are left as bare shells,
# reproducing the reported race where the typed self-exit command never ran.
#
# Usage: herdr-pool-tab-autoclose-live.sh <repo-root>
#   SCENARIOS="1 2 3"   select scenarios (default all)
#   TEARDOWN_OVERRIDE=  drive a different fm-teardown.sh (negative control)
#   OUT_DIR=            artifact directory (default ./artifacts)
# Lab teardown runs in the EXIT trap; nothing is left behind.
set -u

ROOT=${1:?usage: $0 <repo-root>}
ROOT=$(cd "$ROOT" && pwd -P)
HELPER="$ROOT/bin/fm-herdr-lab.sh"
TEARDOWN=${TEARDOWN_OVERRIDE:-$ROOT/bin/fm-teardown.sh}
OUT=${OUT_DIR:-"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/artifacts"}
mkdir -p "$OUT"

fail() { printf 'not ok - %s\n' "$1" >&2; }
note() { printf '# %s\n' "$*"; }

command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
[ -x "$HELPER" ] || { echo "skip: missing $HELPER"; exit 0; }

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-pool-tab-live.XXXXXX")
SESSION=
cleanup() {
  local rc=$?
  if [ -n "$SESSION" ]; then
    "$HELPER" teardown "$SESSION" || rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

SESSION=$("$HELPER" name pooltab) || exit 1
note "lab session: $SESSION"
"$HELPER" provision "$SESSION" || { echo "could not provision lab"; exit 1; }
lab() { "$HELPER" run "$SESSION" "$@"; }

RESULTS="$OUT/results.txt"
: > "$RESULTS"
record() { # <scenario> <pass|fail> <detail>
  printf '%s\t%s\t%s\n' "$2" "$1" "$3" | tee -a "$RESULTS" >&2
}

# ---------------------------------------------------------------------------
# Disposable task home + git fixture (same shape as tests/fm-teardown.test.sh
# make_case, with the REAL herdr CLI instead of its fake).
# ---------------------------------------------------------------------------
make_case() { # <name> -> echoes case dir
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" "$fakebin"

  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin"/*

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main
  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

# Real herdr fixture: one focused anchor workspace, then the task workspace.
make_herdr_task() { # <case dir> <workspace label> -> "ws<TAB>pane<TAB>tab"
  local case_dir=$1 label=$2 anchor out
  anchor=$(lab workspace create --cwd "$case_dir" --label "anchor-$$" --focus) || return 1
  printf '%s' "$anchor" | jq -e '.result.workspace.workspace_id' >/dev/null || return 1
  out=$(lab workspace create --cwd "$case_dir/wt" --label "$label" --no-focus) || return 1
  printf '%s\t%s\t%s\n' \
    "$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id')" \
    "$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id')" \
    "$(printf '%s' "$out" | jq -r '.result.tab.tab_id')"
}

new_tab() { # <workspace> <cwd> <label> -> "pane<TAB>tab"
  local ws=$1 cwd=$2 label=$3 out
  out=$(lab tab create --workspace "$ws" --label "$label" --cwd "$cwd" --no-focus) || return 1
  printf '%s\t%s\n' \
    "$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id')" \
    "$(printf '%s' "$out" | jq -r '.result.tab.tab_id')"
}

write_meta() { # <case dir> <lab> <ws> <pane> <tab>
  local case_dir=$1 session=$2 ws=$3 pane=$4 tab=$5
  cat > "$case_dir/state/task-x1.meta" <<EOF
window=$session:$pane
endpoint_task_id=task-x1
worktree=$case_dir/wt
project=$case_dir/project
kind=ship
mode=local-only
spawn_gen=pool-tab-live-$$
backend=herdr
herdr_session=$session
herdr_workspace_id=$ws
herdr_tab_id=$tab
herdr_pane_id=$pane
EOF
}

run_teardown() { # <case dir> <stdout file> <stderr file>
  local case_dir=$1 so=$2 se=$3
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    -u HERDR_SOCKET_PATH -u HERDR_SESSION -u FM_BACKEND \
    FM_GATE_REFUSE_BYPASS=1 FM_TEST_SEAM=1 FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" \
    PATH="$case_dir/fakebin:$PATH" \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=3 \
    "$TEARDOWN" task-x1 --force > "$so" 2> "$se"
}

pane_gone() { # <pane>
  ! lab pane get "$1" >/dev/null 2>&1
}
workspace_gone() { # <ws>
  ! lab workspace list 2>/dev/null | jq -e --arg ws "$1" '.result.workspaces[]? | select(.workspace_id == $ws)' >/dev/null 2>&1
}
snapshot() { # <case> <tag>
  lab workspace list > "$OUT/$1.$2.workspaces.json"
  lab pane list > "$OUT/$1.$2.panes.json"
}

overall=0

# ---------------------------------------------------------------------------
# Scenario 1: recorded nm-agy review/fix viewer tabs (the reported race) close
# at cleanup, together with the deliver tab, leaving no empty Herdr space.
# ---------------------------------------------------------------------------
scenario1() {
  local case_dir rec ws pane tab d_pane d_tab r_ws r_pane r_tab f_ws f_pane f_tab rc ok=1
  case_dir=$(make_case s1) || { record scenario1 fail "fixture build failed"; return 1; }
  IFS=$'\t' read -r ws pane tab < <(make_herdr_task "$case_dir" "fm-task-x1") || { record scenario1 fail "herdr workspace create failed"; return 1; }
  IFS=$'\t' read -r d_pane d_tab < <(new_tab "$ws" "$case_dir" "deliver: task-x1") || { record scenario1 fail "deliver tab create failed"; return 1; }
  IFS=$'\t' read -r r_pane r_tab < <(new_tab "$ws" "$case_dir" "review: task-x1 (gemini-4-neon-medium)") || { record scenario1 fail "review tab create failed"; return 1; }
  IFS=$'\t' read -r f_pane f_tab < <(new_tab "$ws" "$case_dir" "fix: task-x1 (gemini-4-neon-medium)") || { record scenario1 fail "fix tab create failed"; return 1; }

  # nm-agy record files, written before its `pane run`; the panes below stay
  # bare idle shells because the typed self-exit loop never ran (the race).
  mkdir -p "$case_dir/data/task-x1"
  # bin/fm-deliver.sh records the deliver tab as the bare pane id.
  printf '%s\n' "$d_pane" > "$case_dir/data/task-x1/deliver-tab"
  printf '%s\t%s\n' "$r_pane" "$r_tab" > "$case_dir/data/task-x1/nm-review-tab"
  printf '%s\t%s\n' "$f_pane" "$f_tab" > "$case_dir/data/task-x1/nm-fix-tab"
  printf '%s\t%s\n' "$r_pane" "review:gemini-4-neon-medium" > "$case_dir/data/task-x1/nm-active-tab"
  write_meta "$case_dir" "$SESSION" "$ws" "$pane" "$tab"
  printf 'wG:stale\twG:tStale\n' > "$case_dir/data/task-x1/nm-stale-tab"
  snapshot s1 before

  run_teardown "$case_dir" "$OUT/s1.teardown.stdout" "$OUT/s1.teardown.stderr"
  rc=$?
  echo "teardown rc=$rc" >> "$OUT/s1.teardown.stdout"
  snapshot s1 after

  grep -q "teardown task-x1 complete" "$OUT/s1.teardown.stdout" || { fail "s1: teardown did not report completion"; ok=0; }
  [ "$rc" -eq 0 ] || { fail "s1: teardown exited $rc"; ok=0; }
  pane_gone "$pane" || { fail "s1: task pane survived"; ok=0; }
  pane_gone "$d_pane" || { fail "s1: deliver tab pane survived"; ok=0; }
  pane_gone "$r_pane" || { fail "s1: nm review viewer pane survived"; ok=0; }
  pane_gone "$f_pane" || { fail "s1: nm fix viewer pane survived"; ok=0; }
  workspace_gone "$ws" || { fail "s1: task workspace still standing after cleanup (empty Herdr space)"; ok=0; }
  if [ "$ok" = 1 ]; then
    record "scenario1 recorded nm-agy review/fix viewer tabs and deliver tab close at cleanup, leaving no empty space" pass "task=$pane deliver=$d_pane review=$r_pane fix=$f_pane ws=$ws all gone; teardown rc=0"
  else
    record "scenario1 recorded nm-agy review/fix viewer tabs and deliver tab close at cleanup, leaving no empty space" fail "see $OUT/s1.*"
    overall=1
  fi
}

# ---------------------------------------------------------------------------
# Scenario 2: adversarial records - already-gone pane, the task pane itself,
# an empty record and a whitespace-only record must neither fail nor crash
# teardown, and the workspace still empties.
# ---------------------------------------------------------------------------
scenario2() {
  local case_dir ws pane tab g_pane g_tab r_pane r_tab rc ok=1
  case_dir=$(make_case s2) || { record scenario2 fail "fixture build failed"; return 1; }
  IFS=$'\t' read -r ws pane tab < <(make_herdr_task "$case_dir" "fm-task-x1") || { record scenario2 fail "herdr workspace create failed"; return 1; }
  IFS=$'\t' read -r g_pane g_tab < <(new_tab "$ws" "$case_dir" "gone: task-x1") || { record scenario2 fail "gone tab create failed"; return 1; }
  lab pane close "$g_pane" >/dev/null 2>&1 || true   # already-gone record, like a stale file
  IFS=$'\t' read -r r_pane r_tab < <(new_tab "$ws" "$case_dir" "review: task-x1 (gemini-4-neon-medium)") || { record scenario2 fail "review tab create failed"; return 1; }

  mkdir -p "$case_dir/data/task-x1"
  printf '%s\t%s\n' "$r_pane" "$r_tab" > "$case_dir/data/task-x1/nm-review-tab"
  printf '%s\t%s\n' "$g_pane" "$g_tab" > "$case_dir/data/task-x1/nm-fix-tab"
  printf '%s\t%s\n' "$pane" "$tab" > "$case_dir/data/task-x1/nm-extra-tab"
  : > "$case_dir/data/task-x1/nm-empty-tab"
  printf '   \n' > "$case_dir/data/task-x1/nm-blank-tab"
  write_meta "$case_dir" "$SESSION" "$ws" "$pane" "$tab"
  snapshot s2 before

  run_teardown "$case_dir" "$OUT/s2.teardown.stdout" "$OUT/s2.teardown.stderr"
  rc=$?
  echo "teardown rc=$rc" >> "$OUT/s2.teardown.stdout"
  snapshot s2 after

  [ "$rc" -eq 0 ] || { fail "s2: teardown exited $rc on stale/blank/self records"; ok=0; }
  grep -q "teardown task-x1 complete" "$OUT/s2.teardown.stdout" || { fail "s2: teardown did not report completion"; ok=0; }
  pane_gone "$r_pane" || { fail "s2: surviving recorded viewer pane was left open"; ok=0; }
  workspace_gone "$ws" || { fail "s2: task workspace still standing"; ok=0; }
  if [ "$ok" = 1 ]; then
    record "scenario2 stale, self-referential, empty and blank viewer records skip cleanly while recorded panes still close" pass "gone=$g_pane self=$pane review=$r_pane; teardown rc=0"
  else
    record "scenario2 stale, self-referential, empty and blank viewer records skip cleanly while recorded panes still close" fail "see $OUT/s2.*"
    overall=1
  fi
}

# ---------------------------------------------------------------------------
# Scenario 3: boundary - cleanup closes only recorded panes; an unrecorded
# human tab in the same workspace survives and the workspace is not nuked.
# ---------------------------------------------------------------------------
scenario3() {
  local case_dir ws pane tab h_pane h_tab d_pane d_tab r_pane r_tab rc ok=1
  case_dir=$(make_case s3) || { record scenario3 fail "fixture build failed"; return 1; }
  IFS=$'\t' read -r ws pane tab < <(make_herdr_task "$case_dir" "fm-task-x1") || { record scenario3 fail "herdr workspace create failed"; return 1; }
  IFS=$'\t' read -r d_pane d_tab < <(new_tab "$ws" "$case_dir" "deliver: task-x1") || { record scenario3 fail "deliver tab create failed"; return 1; }
  IFS=$'\t' read -r r_pane r_tab < <(new_tab "$ws" "$case_dir" "review: task-x1 (gemini-4-neon-medium)") || { record scenario3 fail "review tab create failed"; return 1; }
  IFS=$'\t' read -r h_pane h_tab < <(new_tab "$ws" "$case_dir" "scratch: operator") || { record scenario3 fail "human tab create failed"; return 1; }

  mkdir -p "$case_dir/data/task-x1"
  # bin/fm-deliver.sh records the deliver tab as the bare pane id.
  printf '%s\n' "$d_pane" > "$case_dir/data/task-x1/deliver-tab"
  printf '%s\t%s\n' "$r_pane" "$r_tab" > "$case_dir/data/task-x1/nm-review-tab"
  write_meta "$case_dir" "$SESSION" "$ws" "$pane" "$tab"
  snapshot s3 before

  run_teardown "$case_dir" "$OUT/s3.teardown.stdout" "$OUT/s3.teardown.stderr"
  rc=$?
  echo "teardown rc=$rc" >> "$OUT/s3.teardown.stdout"
  snapshot s3 after

  [ "$rc" -eq 0 ] || { fail "s3: teardown exited $rc"; ok=0; }
  grep -q "teardown task-x1 complete" "$OUT/s3.teardown.stdout" || { fail "s3: teardown did not report completion"; ok=0; }
  pane_gone "$pane" || { fail "s3: task pane survived"; ok=0; }
  pane_gone "$d_pane" || { fail "s3: deliver tab pane survived"; ok=0; }
  pane_gone "$r_pane" || { fail "s3: recorded review viewer pane survived"; ok=0; }
  if ! lab pane get "$h_pane" >/dev/null 2>&1; then
    fail "s3: the unrecorded operator tab was closed (workspace nuke)"; ok=0
  fi
  if ! lab workspace list | jq -e --arg ws "$ws" '.result.workspaces[]? | select(.workspace_id == $ws)' >/dev/null 2>&1; then
    fail "s3: workspace holding the unrecorded tab was removed"; ok=0
  fi
  if [ "$ok" = 1 ]; then
    record "scenario3 cleanup closes only recorded panes and leaves an unrecorded operator tab and its workspace intact" pass "task=$pane deliver=$d_pane review=$r_pane closed; operator tab $h_pane survives in $ws"
  else
    record "scenario3 cleanup closes only recorded panes and leaves an unrecorded operator tab and its workspace intact" fail "see $OUT/s3.*"
    overall=1
  fi
}

for _s in ${SCENARIOS:-1 2 3}; do
  "scenario$_s"
done
exit "$overall"
