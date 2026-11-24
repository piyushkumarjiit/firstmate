#!/usr/bin/env bash
# Unit tests for bin/fm-deliver.sh runner refusals and execution preconditions.
# All tests use local temporary fixtures and stubs (no real agy, no sudo, no network).
set -u

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DELIVER="$ROOT/bin/fm-deliver.sh"

TMP_ROOT=$(fm_test_tmproot fm-deliver)

setup_fixture() {
  local tdir="$TMP_ROOT/$1"
  mkdir -p "$tdir/state" "$tdir/data/$1" "$tdir/wt"

  git -C "$tdir/wt" init -q -b "fm/$1"
  git -C "$tdir/wt" config user.email "test@example.com"
  git -C "$tdir/wt" config user.name "Test"
  echo "content" > "$tdir/wt/file.txt"
  git -C "$tdir/wt" add file.txt
  git -C "$tdir/wt" commit -q -m "initial commit"
  local sha
  sha=$(git -C "$tdir/wt" rev-parse HEAD)

  cat > "$tdir/state/$1.meta" << EOF
endpoint_task_id=$1
worktree=$tdir/wt
branch=fm/$1
mode=local-only
EOF

  echo "done [at=1000]: committed $sha" > "$tdir/state/$1.status"

  cat > "$tdir/data/$1/brief.md" << "EOF"
# Task
## Captain's intent
Implement feature safely
## Firstmate spec
Specifications here
EOF

  printf '%s' "$sha"
}

test_refuse_non_main_user() {
  local sha
  sha=$(setup_fixture task_user)
  local tdir="$TMP_ROOT/task_user"

  local err rc=0
  err=$(env FM_HOME="$tdir" FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_MAIN_USER="different_user_xyz" "$DELIVER" task_user run 2>&1) || rc=$?

  [ "$rc" -eq 1 ] || fail "expected exit 1 on non-main user, got $rc"
  assert_contains "$err" "must run as main account" "error must name main account requirement"
  pass "refuses non-main user"
}

test_refuse_missing_or_mismatched_meta() {
  local sha
  sha=$(setup_fixture task_meta)
  local tdir="$TMP_ROOT/task_meta"

  # Mismatched endpoint_task_id
  sed -i 's/endpoint_task_id=task_meta/endpoint_task_id=other_task/' "$tdir/state/task_meta.meta"
  local err rc=0
  err=$(env FM_HOME="$tdir" FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_MAIN_USER="$(id -un)" "$DELIVER" task_meta run 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "expected exit 1 on mismatched meta, got $rc"
  assert_contains "$err" "does not match task" "error must name meta task mismatch"

  # Missing meta file
  rm -f "$tdir/state/task_meta.meta"
  rc=0
  err=$(env FM_HOME="$tdir" FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_MAIN_USER="$(id -un)" "$DELIVER" task_meta run 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "expected exit 1 on missing meta, got $rc"
  assert_contains "$err" "does not exist" "error must report meta missing"

  pass "refuses missing or mismatched meta"
}

test_refuse_worktree_branch_mismatch() {
  local sha
  sha=$(setup_fixture task_branch)
  local tdir="$TMP_ROOT/task_branch"

  git -C "$tdir/wt" checkout -q -b wrong-branch
  local err rc=0
  err=$(env FM_HOME="$tdir" FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_MAIN_USER="$(id -un)" "$DELIVER" task_branch run 2>&1) || rc=$?

  [ "$rc" -eq 1 ] || fail "expected exit 1 on branch mismatch, got $rc"
  assert_contains "$err" "does not match meta branch" "error must report branch mismatch"
  pass "refuses worktree branch mismatch"
}

test_refuse_dirty_worktree() {
  local sha
  sha=$(setup_fixture task_dirty)
  local tdir="$TMP_ROOT/task_dirty"

  echo "uncommitted change" >> "$tdir/wt/file.txt"
  local err rc=0
  err=$(env FM_HOME="$tdir" FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_MAIN_USER="$(id -un)" "$DELIVER" task_dirty run 2>&1) || rc=$?

  [ "$rc" -eq 1 ] || fail "expected exit 1 on dirty tree, got $rc"
  assert_contains "$err" "has uncommitted changes" "error must report uncommitted changes"
  pass "refuses dirty worktree"
}

test_refuse_head_sha_mismatch() {
  local sha
  sha=$(setup_fixture task_sha)
  local tdir="$TMP_ROOT/task_sha"

  echo "extra" > "$tdir/wt/extra.txt"
  git -C "$tdir/wt" add extra.txt
  git -C "$tdir/wt" commit -q -m "extra commit"

  local err rc=0
  err=$(env FM_HOME="$tdir" FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_MAIN_USER="$(id -un)" "$DELIVER" task_sha run 2>&1) || rc=$?

  [ "$rc" -eq 1 ] || fail "expected exit 1 on HEAD sha mismatch, got $rc"
  assert_contains "$err" "does not match worker committed SHA" "error must report sha mismatch"
  pass "refuses HEAD sha mismatch"
}

test_refuse_yes_in_respond() {
  local sha
  sha=$(setup_fixture task_yes)
  local tdir="$TMP_ROOT/task_yes"

  local err rc=0
  err=$(env FM_HOME="$tdir" FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_MAIN_USER="$(id -un)" "$DELIVER" task_yes respond --action approve --yes 2>&1) || rc=$?

  [ "$rc" -eq 1 ] || fail "expected exit 1 when --yes passed to respond, got $rc"
  assert_contains "$err" "--yes is banned" "error must report --yes banned"

  rc=0
  err=$(env FM_HOME="$tdir" FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_MAIN_USER="$(id -un)" "$DELIVER" task_yes respond -y 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "expected exit 1 when -y passed to respond, got $rc"
  assert_contains "$err" "--yes is banned" "error must report -y banned"

  pass "refuses --yes in respond"
}

test_sync_action_allowlist_and_unexpected_blocking() {
  local sha
  sha=$(setup_fixture task_sync)
  local tdir="$TMP_ROOT/task_sync"
  mkdir -p "$tdir/bin"

  # Stub no-mistakes that returns an unexpected next_action command
  cat > "$tdir/bin/no-mistakes" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "axi" && "${2:-}" == "run" ]]; then
  echo "run completed"
  exit 0
elif [[ "${1:-}" == "axi" && "${2:-}" == "status" ]]; then
  cat <<'TOON'
run:
  id: "01TEST"
  status: completed
outcome: passed
branch_sync:
  next_action:
    command: "unexpected-sync-utility --force"
TOON
  exit 0
fi
exit 0
EOF
  chmod +x "$tdir/bin/no-mistakes"

  env PATH="$tdir/bin:$PATH" FM_HOME="$tdir" \
    FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_MAIN_USER="$(id -un)" FM_DELIVER_FOREGROUND=1 \
    "$DELIVER" task_sync run >/dev/null 2>&1 || true

  local last_status
  last_status=$(tail -n 1 "$tdir/state/task_sync.status")
  assert_contains "$last_status" "blocked" "status must be blocked"
  assert_contains "$last_status" "unexpected sync action unexpected-sync-utility --force" "status must name unexpected action"

  # Now test allowlisted command: "no-mistakes axi sync --recover"
  cat > "$tdir/bin/no-mistakes" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "axi" && "${2:-}" == "run" ]]; then
  echo "run completed"
  exit 0
elif [[ "${1:-}" == "axi" && "${2:-}" == "status" ]]; then
  cat <<'TOON'
run:
  id: "01TEST"
  status: completed
outcome: passed
branch_sync:
  next_action:
    command: "no-mistakes axi sync --recover"
TOON
  exit 0
elif [[ "${1:-}" == "axi" && "${2:-}" == "sync" && "${3:-}" == "--recover" ]]; then
  echo "allowlisted sync ran successfully"
  exit 0
fi
exit 0
EOF
  chmod +x "$tdir/bin/no-mistakes"

  env PATH="$tdir/bin:$PATH" FM_HOME="$tdir" \
    FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_MAIN_USER="$(id -un)" FM_DELIVER_FOREGROUND=1 \
    "$DELIVER" task_sync run >/dev/null 2>&1 || true

  last_status=$(tail -n 1 "$tdir/state/task_sync.status")
  assert_contains "$last_status" "done" "allowlisted sync must conclude with done"

  pass "sync action allowlist executes valid commands as argv and blocks unexpected actions"
}

test_respond_resolves_open_gate_key() {
  local sha
  sha=$(setup_fixture task_resolve)
  local tdir="$TMP_ROOT/task_resolve"
  mkdir -p "$tdir/bin"

  cat > "$tdir/bin/no-mistakes" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$tdir/bin/no-mistakes"

  # Case 1: Status file has open gate-review
  echo "needs-decision [at=100] [key=gate-review]: review findings" >> "$tdir/state/task_resolve.status"

  env PATH="$tdir/bin:$PATH" FM_HOME="$tdir" \
    FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_MAIN_USER="$(id -un)" \
    "$DELIVER" task_resolve respond --action fix --findings review-1 --ignore review-2 >/dev/null 2>&1

  local resolved_line
  resolved_line=$(grep 'resolved.*\[key=gate-review\]' "$tdir/state/task_resolve.status" || true)
  [ -n "$resolved_line" ] || fail "respond must append resolved line for open gate key"
  assert_contains "$resolved_line" "firstmate responded fix findings=review-1 ignore=review-2" \
    "resolved line must record firstmate action and findings"

  # Case 2: No open gate key (it was already resolved)
  local lines_before lines_after
  lines_before=$(wc -l < "$tdir/state/task_resolve.status")

  env PATH="$tdir/bin:$PATH" FM_HOME="$tdir" \
    FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_MAIN_USER="$(id -un)" \
    "$DELIVER" task_resolve respond --action approve >/dev/null 2>&1

  lines_after=$(wc -l < "$tdir/state/task_resolve.status")
  [ "$lines_before" -eq "$lines_after" ] || fail "respond must append nothing when no open gate key exists"

  pass "respond resolves open gate key with action and ids, and appends nothing when none open"
}

test_run_intent_includes_firstmate_decisions() {
  local sha
  sha=$(setup_fixture task_decisions)
  local tdir="$TMP_ROOT/task_decisions"
  mkdir -p "$tdir/bin"

  local captured_intent="$tdir/captured_intent.txt"
  cat > "$tdir/bin/no-mistakes" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "axi" && "\${2:-}" == "run" ]]; then
  while [[ \$# -gt 0 ]]; do
    if [[ "\$1" == "--intent" ]]; then
      printf '%s\n' "\$2" > "$captured_intent"
      break
    fi
    shift
  done
  exit 0
elif [[ "\${1:-}" == "axi" && "\${2:-}" == "status" ]]; then
  cat <<'TOON'
run:
  id: "01TEST"
  status: completed
outcome: passed
branch_sync:
  next_action:
    command: "no-mistakes axi sync --recover"
TOON
  exit 0
elif [[ "\${1:-}" == "axi" && "\${2:-}" == "sync" ]]; then
  exit 0
fi
exit 0
EOF
  chmod +x "$tdir/bin/no-mistakes"

  # Append decisions to status file: one non-gate decision, one gate decision, one non-answered line
  cat >> "$tdir/state/task_decisions.status" <<'EOF'
resolved [key=over-max] [at=1000]: answered: clamp
resolved [key=gate-review] [at=1001]: answered: proceed
resolved [key=formatting]: formatted successfully
EOF

  env PATH="$tdir/bin:$PATH" FM_HOME="$tdir" \
    FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_MAIN_USER="$(id -un)" FM_DELIVER_FOREGROUND=1 \
    "$DELIVER" task_decisions run >/dev/null 2>&1 || true

  local intent
  intent=$(cat "$captured_intent")
  assert_contains "$intent" "Implement feature safely" "intent must contain Captain's intent"
  assert_contains "$intent" "## Firstmate decisions" "intent must contain Firstmate decisions heading"
  assert_contains "$intent" "resolved [key=over-max] [at=1000]: answered: clamp" "intent must contain non-gate decision line verbatim"
  assert_not_contains "$intent" "gate-review" "intent must not contain gate-* decision lines"
  assert_not_contains "$intent" "formatting" "intent must not contain non-answered resolved lines"

  pass "run appends Firstmate decisions block from status file to intent"
}

test_run_opens_progress_tab_on_herdr() {
  local sha
  sha=$(setup_fixture task_tab)
  local tdir="$TMP_ROOT/task_tab"
  mkdir -p "$tdir/bin"
  cat > "$tdir/bin/no-mistakes" <<'EOF2'
#!/usr/bin/env bash
exit 0
EOF2
  cat > "$tdir/bin/herdr" <<EOF2
#!/usr/bin/env bash
echo "\$*" >> "$tdir/herdr.log"
case "\$1 \$2" in
  "tab create") echo '{"result":{"root_pane":{"pane_id":"wX:p9"}}}' ;;
  "pane get") exit 1 ;;
esac
exit 0
EOF2
  chmod +x "$tdir/bin/no-mistakes" "$tdir/bin/herdr"
  printf 'backend=herdr\nherdr_workspace_id=wX\n' >> "$tdir/state/task_tab.meta"

  env PATH="$tdir/bin:$PATH" FM_HOME="$tdir" \
    FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_MAIN_USER="$(id -un)" \
    "$DELIVER" task_tab run >/dev/null 2>&1 || true

  local log
  log=$(cat "$tdir/herdr.log" 2>/dev/null || true)
  assert_contains "$log" "tab create --workspace wX --label deliver: task_tab" "run must open a labelled tab in the task workspace"
  assert_contains "$log" "pane run wX:p9" "run must start the live log view in the new tab"
  assert_contains "$log" "drive.log" "the tab must follow the drive log"
  assert_contains "$(cat "$tdir/data/task_tab/deliver-tab")" "wX:p9" "the tab pane must be recorded for reuse"

  : > "$tdir/herdr.log"
  env PATH="$tdir/bin:$PATH" FM_HOME="$tdir" \
    FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_MAIN_USER="$(id -un)" FM_DELIVER_TAB=off \
    "$DELIVER" task_tab run >/dev/null 2>&1 || true
  assert_not_contains "$(cat "$tdir/herdr.log" 2>/dev/null || true)" "tab create" "FM_DELIVER_TAB=off must not open a tab"

  pass "run opens a live delivery progress tab on herdr-backed tasks"
}

test_run_reattaches_while_run_in_progress() {
  local sha
  sha=$(setup_fixture task_reattach)
  local tdir="$TMP_ROOT/task_reattach"
  mkdir -p "$tdir/bin"
  # First two status reads report a still-running run; then it passes.
  cat > "$tdir/bin/no-mistakes" <<EOF2
#!/usr/bin/env bash
if [[ "\${1:-} \${2:-}" == "axi run" ]]; then
  echo "run-call \$*" >> "$tdir/calls.log"
  echo "outcome: failed (stale line from an older run)"
  exit 0
elif [[ "\${1:-} \${2:-}" == "axi status" ]]; then
  n=\$(cat "$tdir/n" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$tdir/n"
  if (( n <= 2 )); then
    printf 'run:\n  id: "01R"\n  status: running\n  awaiting_agent: parked 1m\n'
  else
    printf 'run:\n  id: "01R"\n  status: completed\noutcome: passed\nbranch_sync:\n  next_action:\n    command: "no-mistakes axi sync"\n'
  fi
  exit 0
fi
exit 0
EOF2
  chmod +x "$tdir/bin/no-mistakes"

  env PATH="$tdir/bin:$PATH" FM_HOME="$tdir" \
    FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_MAIN_USER="$(id -un)" FM_DELIVER_FOREGROUND=1 \
    "$DELIVER" task_reattach run >/dev/null 2>&1 || true

  local last_status calls
  last_status=$(tail -n 1 "$tdir/state/task_reattach.status")
  calls=$(grep -c '^run-call' "$tdir/calls.log" || true)
  assert_contains "$last_status" "done" "a run that is still in progress must be reattached, then its real outcome reported"
  assert_not_contains "$last_status" "failed" "a stale outcome line in the drive log must never be read as this run's outcome"
  [ "$calls" -ge 3 ] || fail "expected the initial run plus 2 reattaches, got $calls run calls"

  pass "run reattaches while the pipeline is still in progress and ignores stale log outcomes"
}

test_ready_condition() {
  local sha
  sha=$(setup_fixture task_ready)
  local tdir="$TMP_ROOT/task_ready"
  mkdir -p "$tdir/bin"
  cat > "$tdir/bin/no-mistakes" <<EOF2
#!/usr/bin/env bash
[[ -f "$tdir/run_head" ]] && printf 'run:\n  head_sha: "%s"\n' "\$(cat "$tdir/run_head")"
exit 0
EOF2
  chmod +x "$tdir/bin/no-mistakes"
  ready() {
    env PATH="$tdir/bin:$PATH" FM_HOME="$tdir" FM_STATE_OVERRIDE="$tdir/state" \
      FM_DATA_OVERRIDE="$tdir/data" FM_MAIN_USER="$(id -un)" "$DELIVER" task_ready ready >/dev/null 2>&1
  }
  ready || fail "a fresh done: committed report with no run for that head must be ready"
  echo "$sha" > "$tdir/run_head"
  ! ready || fail "a head that already has a validation run must not be ready again"
  rm -f "$tdir/run_head"
  echo "working [at=1]: fixing review findings" >> "$tdir/state/task_ready.status"
  ! ready || fail "a later working report must make the task not ready"
  pass "ready fires only on a fresh committed report without a run for that head"
}

fm_test_run \
  test_ready_condition \
  test_refuse_non_main_user \
  test_refuse_missing_or_mismatched_meta \
  test_refuse_worktree_branch_mismatch \
  test_refuse_dirty_worktree \
  test_refuse_head_sha_mismatch \
  test_refuse_yes_in_respond \
  test_sync_action_allowlist_and_unexpected_blocking \
  test_respond_resolves_open_gate_key \
  test_run_intent_includes_firstmate_decisions \
  test_run_opens_progress_tab_on_herdr \
  test_run_reattaches_while_run_in_progress
