#!/usr/bin/env bash
# Unit tests for bin/fm-deliver.sh runner refusals and execution preconditions.
# All tests use local temporary fixtures and stubs (no real agy, no sudo, no network).
set -u

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DELIVER="$ROOT/bin/fm-deliver.sh"
NL=$'\n'

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

test_respond_keeps_gate_open_when_respond_fails() {
  local sha
  sha=$(setup_fixture task_respond_fail)
  local tdir="$TMP_ROOT/task_respond_fail"
  mkdir -p "$tdir/bin"

  cat > "$tdir/bin/no-mistakes" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-}" == "axi respond" ]]; then
  echo "error: no active run to respond to" >&2
  exit 1
fi
exit 0
EOF
  chmod +x "$tdir/bin/no-mistakes"

  echo "needs-decision [at=100] [key=gate-review]: review findings" >> "$tdir/state/task_respond_fail.status"

  local rc=0
  env PATH="$tdir/bin:$PATH" FM_HOME="$tdir" \
    FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_MAIN_USER="$(id -un)" \
    "$DELIVER" task_respond_fail respond --action fix --findings f1 >/dev/null 2>&1 || rc=$?

  [ "$rc" -ne 0 ] || fail "respond must exit nonzero when no-mistakes axi respond fails"
  if grep -q 'resolved.*\[key=gate-review\]' "$tdir/state/task_respond_fail.status"; then
    fail "gate must stay open when the answer never reached the run: $(cat "$tdir/state/task_respond_fail.status")"
  fi

  pass "respond keeps the gate open and exits nonzero when the answer is not delivered"
}

test_respond_closes_every_named_gate_key() {
  local sha
  sha=$(setup_fixture task_respond_multi)
  local tdir="$TMP_ROOT/task_respond_multi"
  mkdir -p "$tdir/bin"

  cat > "$tdir/bin/no-mistakes" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$tdir/bin/no-mistakes"

  cat >> "$tdir/state/task_respond_multi.status" <<'EOF'
needs-decision [at=100] [key=gate-review]: review findings
needs-decision [at=101] [key=gate-fix]: fix findings
needs-decision [at=102] [key=gate-ci]: ci findings
EOF

  local rc=0
  env PATH="$tdir/bin:$PATH" FM_HOME="$tdir" \
    FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_MAIN_USER="$(id -un)" FM_DELIVER_GATE_KEYS="gate-review gate-fix" \
    "$DELIVER" task_respond_multi respond --action approve >/dev/null 2>&1 || rc=$?

  [ "$rc" -eq 0 ] || fail "responding to two named gate keys must succeed, got $rc"
  grep -q 'resolved.*\[key=gate-review\]' "$tdir/state/task_respond_multi.status" \
    || fail "every named gate key must be closed: $(cat "$tdir/state/task_respond_multi.status")"
  grep -q 'resolved.*\[key=gate-fix\]' "$tdir/state/task_respond_multi.status" \
    || fail "every named gate key must be closed: $(cat "$tdir/state/task_respond_multi.status")"
  if grep -q 'resolved.*\[key=gate-ci\]' "$tdir/state/task_respond_multi.status"; then
    fail "gate keys not named in the send must stay open: $(cat "$tdir/state/task_respond_multi.status")"
  fi

  pass "respond closes every named gate key and leaves unnamed ones open"
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

test_run_exits_finished_pool_builder_once() {
  local sha tdir ctl_log
  sha=$(setup_fixture task_slot)
  tdir="$TMP_ROOT/task_slot"
  ctl_log="$tdir/control.log"
  mkdir -p "$tdir/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tdir/bin/no-mistakes"
  # shellcheck disable=SC2016  # the stub script expands its own variables
  printf '#!/usr/bin/env bash\necho "$*" >> %q\nexit "${FAKE_CONTROL_RC:-0}"\n' "$ctl_log" > "$tdir/control"
  chmod +x "$tdir/bin/no-mistakes" "$tdir/control"
  printf 'builder=pool\nharness=agy\n' >> "$tdir/state/task_slot.meta"
  run_slot() {
    env PATH="$tdir/bin:$PATH" FM_HOME="$tdir" FM_STATE_OVERRIDE="$tdir/state" \
      FM_DATA_OVERRIDE="$tdir/data" FM_MAIN_USER="$(id -un)" FM_DELIVER_TAB=off \
      FM_DELIVER_CONTROL="$tdir/control" "$@" "$DELIVER" task_slot run >/dev/null 2>&1 || true
  }

  # A refused exit is logged, keeps delivery going, and is retried next run.
  run_slot env FAKE_CONTROL_RC=1
  [ "$(cat "$ctl_log")" = "task_slot exit" ] || fail "run must exit the finished pool builder through fm-control, got: $(cat "$ctl_log" 2>/dev/null)"
  assert_contains "$(cat "$tdir/data/task_slot/drive.log")" "slot stays held" "a refused exit must be logged"
  [ ! -e "$tdir/data/task_slot/pool-slot-released" ] || fail "a refused exit must not record the slot as released"

  : > "$ctl_log"
  run_slot env FAKE_CONTROL_RC=0
  [ "$(cat "$ctl_log")" = "task_slot exit" ] || fail "retry must exit the builder, got: $(cat "$ctl_log")"
  [ -e "$tdir/data/task_slot/pool-slot-released" ] || fail "a successful exit must record the release"

  : > "$ctl_log"
  run_slot env FAKE_CONTROL_RC=0
  [ ! -s "$ctl_log" ] || fail "an already released builder must not be exited again"
  pass "run exits a finished pool builder once and keeps delivery going on refusal"
}

test_run_keeps_pool_builder_with_open_decision_or_other_shape() {
  local sha tdir
  sha=$(setup_fixture task_slot2)
  tdir="$TMP_ROOT/task_slot2"
  mkdir -p "$tdir/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tdir/bin/no-mistakes"
  printf '#!/usr/bin/env bash\necho "$*" >> %q\n' "$tdir/control.log" > "$tdir/control"
  chmod +x "$tdir/bin/no-mistakes" "$tdir/control"
  run_slot2() {
    env PATH="$tdir/bin:$PATH" FM_HOME="$tdir" FM_STATE_OVERRIDE="$tdir/state" \
      FM_DATA_OVERRIDE="$tdir/data" FM_MAIN_USER="$(id -un)" FM_DELIVER_TAB=off \
      FM_DELIVER_CONTROL="$tdir/control" "$DELIVER" task_slot2 run >/dev/null 2>&1 || true
  }

  # Not a pool builder: untouched.
  printf 'harness=agy\n' >> "$tdir/state/task_slot2.meta"
  run_slot2
  [ ! -e "$tdir/control.log" ] || fail "a non-pool task must not be exited"

  # A pool builder with an unresolved keyed decision keeps its agent.
  printf 'builder=pool\n' >> "$tdir/state/task_slot2.meta"
  { printf 'needs-decision [at=1] [key=k1]: pick\n'; cat "$tdir/state/task_slot2.status"; } > "$tdir/status.new"
  mv "$tdir/status.new" "$tdir/state/task_slot2.status"
  run_slot2
  [ ! -e "$tdir/control.log" ] || fail "an open keyed decision must keep the builder running"
  assert_contains "$(cat "$tdir/data/task_slot2/drive.log")" "open decision or blocker (k1)" "the open key must be named"

  # Once resolved, the builder is exited.
  printf 'resolved [at=2] [key=k1]: answered\n' >> "$tdir/state/task_slot2.status"
  printf '%s\n' "done [at=3]: committed $sha" >> "$tdir/state/task_slot2.status"
  run_slot2
  [ "$(cat "$tdir/control.log")" = "task_slot2 exit" ] || fail "a resolved decision must let the builder exit"
  pass "run never exits a non-pool task or a builder with an open decision"
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

test_respond_normalizes_supervisor_forms() {
  local sha
  sha=$(setup_fixture task_norm)
  local tdir="$TMP_ROOT/task_norm"
  mkdir -p "$tdir/bin"

  local nm_log="$tdir/nm.log"
  cat > "$tdir/bin/no-mistakes" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$nm_log"
exit 0
EOF
  chmod +x "$tdir/bin/no-mistakes"

  # 1. Single-string supervisor form: "fix findings=a,b ignore=c"
  echo "needs-decision [at=100] [key=gate-review]: a, b, c" >> "$tdir/state/task_norm.status"
  env PATH="$tdir/bin:$PATH" FM_HOME="$tdir" \
    FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_MAIN_USER="$(id -un)" \
    "$DELIVER" task_norm respond "fix findings=a,b ignore=c" >/dev/null 2>&1
  assert_contains "$(cat "$nm_log")" "axi respond --action fix --findings a,b --ignore c" \
    "supervisor string must normalize to axi respond flags"
  assert_contains "$(grep 'resolved.*\[key=gate-review\]' "$tdir/state/task_norm.status")" \
    "firstmate responded fix findings=a,b ignore=c" \
    "resolved line must record normalized action and ids"

  # 2. Separate token args: approve reason=looks good
  : > "$nm_log"
  echo "needs-decision [at=101] [key=gate-approval]: confirm" >> "$tdir/state/task_norm.status"
  env PATH="$tdir/bin:$PATH" FM_HOME="$tdir" \
    FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_MAIN_USER="$(id -un)" \
    "$DELIVER" task_norm respond approve reason="all checks green" >/dev/null 2>&1
  assert_contains "$(cat "$nm_log")" "axi respond --action approve --reason all checks green" \
    "approve with reason must normalize to --action approve --reason"

  # 3. Unrecognized or banned answer refuses before writing resolved
  : > "$nm_log"
  echo "needs-decision [at=102] [key=gate-final]: pick" >> "$tdir/state/task_norm.status"
  local rc=0
  env PATH="$tdir/bin:$PATH" FM_HOME="$tdir" \
    FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_MAIN_USER="$(id -un)" \
    "$DELIVER" task_norm respond "maybe later" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || fail "unrecognized answer must exit 1, got $rc"
  [ ! -s "$nm_log" ] || fail "unrecognized answer must not invoke no-mistakes"
  ! grep -q 'resolved.*\[key=gate-final\]' "$tdir/state/task_norm.status" \
    || fail "unrecognized answer must not write resolved line"

  rc=0
  env PATH="$tdir/bin:$PATH" FM_HOME="$tdir" \
    FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_MAIN_USER="$(id -un)" \
    "$DELIVER" task_norm respond "yes" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || fail "banned yes answer must exit 1, got $rc"

  pass "respond normalizes supervisor forms and refuses invalid/banned answers before writing resolved"
}

test_run_resolves_roles_and_nm_agy_consumes_them() {
  local sha
  sha=$(setup_fixture task_roles)
  local tdir="$TMP_ROOT/task_roles"
  mkdir -p "$tdir/bin" "$tdir/config" "$tdir/logs"

  cat > "$tdir/config/crew-dispatch.json" <<'JSON'
{
  "roles": {
    "review": [
      { "harness": "agy", "model": "gemini-4-neon-high", "account": "neon_acct" },
      { "harness": "agy", "model": "gemini-3.8-flash-high" }
    ],
    "fix": [
      { "harness": "agy", "model": "gemini-4-hydrogen-high" }
    ]
  },
  "default": { "harness": "agy", "model": "gemini-3.8-flash-high" }
}
JSON

  # Fake pool wrapper called by nm-agy
  cat > "$tdir/bin/fake-pool" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tdir/pool-args.log"
exit 0
EOF
  chmod +x "$tdir/bin/fake-pool"

  # Stub no-mistakes that invokes the real bin/agy-pool/nm-agy for review and fix
  local nm_agy="$ROOT/bin/agy-pool/nm-agy"
  cat > "$tdir/bin/no-mistakes" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-} \${2:-}" == "axi run" ]]; then
  printf 'REVIEW_MODEL=%s REVIEW_ACCT=%s FIX_MODEL=%s FIX_ACCT=%s\n' \
    "\${FM_NM_REVIEW_MODEL:-}" "\${FM_NM_REVIEW_ACCOUNT:-}" \
    "\${FM_NM_FIX_MODEL:-}" "\${FM_NM_FIX_ACCOUNT:-}" > "$tdir/env.log"
  FM_HOME="$tdir" FM_AGY_POOL_BIN="$tdir/bin/fake-pool" \
    "$nm_agy" --account piyushk --model gemini-4-neon-medium -p "Focus findings on risks introduced by changed code"
  FM_HOME="$tdir" FM_AGY_POOL_BIN="$tdir/bin/fake-pool" \
    "$nm_agy" --account piyushk --model gemini-4-neon-medium -p "Fix finding f1"
  exit 0
elif [[ "\${1:-} \${2:-}" == "axi status" ]]; then
  printf 'run:\n  id: "01ROLES"\n  status: completed\noutcome: passed\nbranch_sync:\n  next_action:\n    command: "no-mistakes axi sync"\n'
  exit 0
fi
exit 0
EOF
  chmod +x "$tdir/bin/no-mistakes"

  env PATH="$tdir/bin:$PATH" FM_HOME="$tdir" \
    FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_CONFIG_OVERRIDE="$tdir/config" FM_AGY_STATE_DIR="$tdir/agy-state" \
    FM_MAIN_USER="$(id -un)" FM_DELIVER_FOREGROUND=1 \
    "$DELIVER" task_roles run >/dev/null 2>&1 || true

  local env_out pool_out
  env_out=$(cat "$tdir/env.log")
  assert_contains "$env_out" "REVIEW_MODEL=gemini-4-neon-high" "fm-deliver must export FM_NM_REVIEW_MODEL from roles.review"
  assert_contains "$env_out" "REVIEW_ACCT=neon_acct" "fm-deliver must export FM_NM_REVIEW_ACCOUNT from roles.review"
  assert_contains "$env_out" "FIX_MODEL=gemini-4-hydrogen-high" "fm-deliver must export FM_NM_FIX_MODEL from roles.fix"
  assert_contains "$env_out" "FIX_ACCT=" "omitted account must leave FM_NM_FIX_ACCOUNT empty"

  pool_out=$(cat "$tdir/pool-args.log")
  assert_contains "$pool_out" "--model gemini-4-neon-high" "nm-agy must use FM_NM_REVIEW_MODEL"
  assert_contains "$pool_out" "--account neon_acct" "nm-agy must pass configured review account"
  assert_contains "$pool_out" "--model gemini-4-hydrogen-high" "nm-agy must use FM_NM_FIX_MODEL"
  # For fix (account omitted in role config), hardcoded --account piyushk must be stripped
  local fix_line
  fix_line=$(grep 'Fix finding f1' <<<"$pool_out" || true)
  [ -n "$fix_line" ] || fail "missing fix call in pool args: $pool_out"
  assert_not_contains "$fix_line" "piyushk" "omitted role account must strip hardcoded --account so pool can rotate"

  local roles_file
  roles_file=$(cat "$tdir/state/task_roles.nm-roles" 2>/dev/null || true)
  assert_contains "$roles_file" "review_model=gemini-4-neon-high" \
    "fm-deliver must persist the resolved review model for daemon-spawned nm-agy"
  assert_contains "$roles_file" "review_account=neon_acct" \
    "fm-deliver must persist the resolved review account"
  assert_contains "$roles_file" "review_fallback=gemini-4-neon-high,gemini-3.8-flash-high" \
    "fm-deliver must persist the review fallback list"
  assert_contains "$roles_file" "fix_model=gemini-4-hydrogen-high" \
    "fm-deliver must persist the resolved fix model"

  # Absent roles preserves legacy defaults and incoming --account
  rm -f "$tdir/config/crew-dispatch.json" "$tdir/pool-args.log" "$tdir/env.log"
  env PATH="$tdir/bin:$PATH" FM_HOME="$tdir" \
    FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_CONFIG_OVERRIDE="$tdir/config" FM_AGY_STATE_DIR="$tdir/agy-state" \
    FM_MAIN_USER="$(id -un)" FM_DELIVER_FOREGROUND=1 \
    "$DELIVER" task_roles run >/dev/null 2>&1 || true
  [ ! -e "$tdir/state/task_roles.nm-roles" ] \
    || fail "absent roles must remove a stale role file so nm-agy keeps its defaults"
  assert_contains "$(cat "$tdir/env.log")" "REVIEW_MODEL= REVIEW_ACCT= FIX_MODEL= FIX_ACCT=" \
    "absent roles must not export FM_NM_* overrides"
  pool_out=$(cat "$tdir/pool-args.log")
  assert_contains "$pool_out" "--account piyushk --model gemini-4-neon-medium" \
    "absent roles must preserve nm-agy legacy model and incoming account"

  pass "fm-deliver run resolves roles.review/roles.fix for nm-agy and preserves defaults when absent"
}

test_quota_failover_restarts_with_next_role_model() {
  local sha
  sha=$(setup_fixture task_failover)
  local tdir="$TMP_ROOT/task_failover"
  mkdir -p "$tdir/bin" "$tdir/config" "$tdir/agy-state"

  cat > "$tdir/config/crew-dispatch.json" <<'JSON'
{
  "roles": {
    "review": [
      { "harness": "agy", "model": "gemini-4-neon-high" },
      { "harness": "agy", "model": "gemini-3.8-flash-high" }
    ],
    "fix": [
      { "harness": "agy", "model": "gemini-4-hydrogen-high" },
      { "harness": "agy", "model": "gemini-3.8-flash-high" }
    ]
  }
}
JSON

  cat > "$tdir/pool.conf" <<'EOF'
acct1
EOF
  cat > "$tdir/models.conf" <<'EOF'
*neon* acct1
EOF

  # Attempt 1: review fails with Individual quota reached + all accounts exhausted -> outcome failed, branch_sync=pipeline_owned
  # Attempt 2: after axi abort + axi sync --recover, runs on same head with gemini-3.8-flash-high and passes
  cat > "$tdir/bin/no-mistakes" <<EOF
#!/usr/bin/env bash
cmd="\${1:-} \${2:-}"
printf '%s|model=%s|head=%s\n' "\$cmd" "\${FM_NM_REVIEW_MODEL:-}" "\$(git rev-parse HEAD)" >> "$tdir/nm-calls.log"
if [[ "\$cmd" == "axi run" ]]; then
  if [[ "\${FM_NM_REVIEW_MODEL:-}" == "gemini-4-neon-high" ]]; then
    echo "antigravity reported error: Individual quota reached. Resets in 2h0m0s." >&2
    echo "antigravity exited pid=4242 error=antigravity reported error: Individual quota reached. Resets in 2h0m0s." >&2
    cat > "$tdir/agy-state/acct1.state.json" <<'JSON'
{"user":"acct1","window_start":1000,"reset_at":9999999999,"used_sec":10,"budget_sec":5400,"exhausted":true}
JSON
    echo "1" > "$tdir/failed_once"
    exit 1
  fi
  rm -f "$tdir/failed_once"
  exit 0
elif [[ "\$cmd" == "axi abort" ]]; then
  rm -f "$tdir/failed_once"
  echo "aborted" > "$tdir/aborted"
  exit 0
elif [[ "\$cmd" == "axi sync" ]]; then
  echo "recovered" > "$tdir/recovered"
  exit 0
elif [[ "\$cmd" == "axi status" ]]; then
  if [[ -f "$tdir/failed_once" ]]; then
    cat <<'TOON'
run:
  id: "01FAIL"
  status: failed
outcome: failed
branch_sync:
  state: pipeline_owned
  next_action:
    command: "no-mistakes axi sync --recover"
TOON
  elif [[ -f "$tdir/aborted" && ! -f "$tdir/recovered" ]]; then
    cat <<'TOON'
branch_sync:
  state: pipeline_owned
  next_action:
    command: "no-mistakes axi sync --recover"
TOON
  else
    cat <<'TOON'
run:
  id: "01PASS"
  status: completed
outcome: passed
branch_sync:
  next_action:
    command: "no-mistakes axi sync"
TOON
  fi
  exit 0
fi
exit 0
EOF
  chmod +x "$tdir/bin/no-mistakes"

  env PATH="$tdir/bin:$PATH" FM_HOME="$tdir" \
    FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_CONFIG_OVERRIDE="$tdir/config" FM_AGY_STATE_DIR="$tdir/agy-state" \
    POOL_CONF="$tdir/pool.conf" MODELS_CONF="$tdir/models.conf" \
    FM_MAIN_USER="$(id -un)" FM_DELIVER_FOREGROUND=1 \
    "$DELIVER" task_failover run >/dev/null 2>&1

  local calls last_status
  calls=$(cat "$tdir/nm-calls.log")
  assert_contains "$calls" "axi run|model=gemini-4-neon-high|head=$sha" "first attempt must use primary model on submitted head"
  assert_contains "$calls" "axi abort|" "failover must abort failed run"
  assert_contains "$calls" "axi sync|" "failover must recover custody when pipeline_owned"
  assert_contains "$calls" "axi run|model=gemini-3.8-flash-high|head=$sha" "second attempt must restart on same head with fallback model"

  last_status=$(tail -n 1 "$tdir/state/task_failover.status")
  assert_contains "$last_status" "done" "failover run must finish with done: $last_status"
  assert_contains "$(cat "$tdir/state/task_failover.status")" "failing over to gemini-3.8-flash-high" \
    "status log must record model failover notice"

  pass "fm-deliver restarts on the same head with the next role fallback model when all accounts are exhausted"
}

test_quota_words_in_agent_answer_do_not_fail_over() {
  local sha
  sha=$(setup_fixture task_quota_words)
  local tdir="$TMP_ROOT/task_quota_words"
  mkdir -p "$tdir/bin" "$tdir/config" "$tdir/agy-state"

  cat > "$tdir/config/crew-dispatch.json" <<'JSON'
{
  "roles": {
    "review": [
      { "harness": "agy", "model": "gemini-4-neon-high" },
      { "harness": "agy", "model": "gemini-3.8-flash-high" }
    ]
  }
}
JSON

  cat > "$tdir/bin/no-mistakes" <<EOF
#!/usr/bin/env bash
cmd="\${1:-} \${2:-}"
printf '%s\n' "\$cmd" >> "$tdir/nm-calls.log"
if [[ "\$cmd" == "axi run" ]]; then
  echo 'finding: the retry path treats Individual quota reached as a bare 429 token'
  echo 'review failed: compile error in src/app.go'
  exit 1
elif [[ "\$cmd" == "axi status" ]]; then
  cat <<'TOON'
run:
  id: "01WORDS"
  status: failed
outcome: failed
TOON
fi
exit 0
EOF
  chmod +x "$tdir/bin/no-mistakes"

  env PATH="$tdir/bin:$PATH" FM_HOME="$tdir" \
    FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_CONFIG_OVERRIDE="$tdir/config" FM_AGY_STATE_DIR="$tdir/agy-state" \
    FM_MAIN_USER="$(id -un)" FM_DELIVER_FOREGROUND=1 \
    "$DELIVER" task_quota_words run >/dev/null 2>&1 || true

  local calls
  calls=$(cat "$tdir/nm-calls.log")
  assert_not_contains "$calls" "axi abort" \
    "a non-quota failure whose findings mention quota words must not abort the run"
  [ "$(grep -c '^axi run$' "$tdir/nm-calls.log")" -eq 1 ] \
    || fail "a non-quota failure must not restart on a fallback model: $calls"

  local last_status
  last_status=$(tail -n 1 "$tdir/state/task_quota_words.status")
  assert_contains "$last_status" "blocked" \
    "a non-quota failure must be reported as blocked: $last_status"

  pass "quota words inside agent findings do not trigger a fallback model restart"
}

test_herdr_visibility_for_nm_agy_and_gate_park() {
  local sha
  sha=$(setup_fixture task_herdr_vis)
  local tdir="$TMP_ROOT/task_herdr_vis"
  mkdir -p "$tdir/bin" "$tdir/nm-wt"
  printf 'backend=herdr\nherdr_workspace_id=wH1\nherdr_session=sH1\n' >> "$tdir/state/task_herdr_vis.meta"

  # Separate no-mistakes checkout on the same branch (simulates
  # ~/.no-mistakes/worktrees/...): branch refs exist in the run repo, but the
  # worktree itself is checked out at a detached HEAD that a fix step has already
  # committed past, as no-mistakes does.
  git -C "$tdir/nm-wt" init -q -b main
  git -C "$tdir/nm-wt" config user.email "test@example.com"
  git -C "$tdir/nm-wt" config user.name "Test"
  echo "base" > "$tdir/nm-wt/base.txt"
  git -C "$tdir/nm-wt" add base.txt
  git -C "$tdir/nm-wt" commit -q -m "base commit"
  git -C "$tdir/nm-wt" checkout -q -b "fm/task_herdr_vis"
  echo "x" > "$tdir/nm-wt/f.txt"
  git -C "$tdir/nm-wt" add f.txt
  git -C "$tdir/nm-wt" commit -q -m "nm mirror commit"
  git -C "$tdir/nm-wt" branch "fm/task_base_ancestor" main
  git -C "$tdir/nm-wt" checkout -q --detach "fm/task_herdr_vis"
  echo "fix" > "$tdir/nm-wt/g.txt"
  git -C "$tdir/nm-wt" add g.txt
  git -C "$tdir/nm-wt" commit -q -m "fix commit on the run worktree"
  [ "$(git -C "$tdir/nm-wt" rev-parse --abbrev-ref HEAD)" = "HEAD" ] \
    || fail "fixture must be a detached-HEAD no-mistakes worktree"
  [ "$(git -C "$tdir/nm-wt" rev-parse HEAD)" != "$(git -C "$tdir/nm-wt" rev-parse refs/heads/fm/task_herdr_vis)" ] \
    || fail "fixture must have committed past the task branch tip"
  printf 'backend=herdr\nherdr_workspace_id=wDecoy\nbranch=fm/task_base_ancestor\n' \
    > "$tdir/state/task_base_ancestor.meta"

  local herdr_log="$tdir/herdr.calls"
  cat > "$tdir/bin/herdr" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$herdr_log"
case "\${1:-} \${2:-}" in
  "tab create")
    echo '{"result":{"tab":{"tab_id":"tH1"},"root_pane":{"pane_id":"wH1:pH1"}}}'
    exit 0
    ;;
  "pane get")
    [[ -f "$tdir/pane_alive" ]] && exit 0
    exit 1
    ;;
esac
exit 0
EOF
  chmod +x "$tdir/bin/herdr"

  cat > "$tdir/bin/fake-pool" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${FM_AGY_RUN_LOG:-}" ]]; then
  echo "live pool output line" >> "$FM_AGY_RUN_LOG"
fi
if [[ "${FAKE_POOL_MODE:-ok}" == "quota" ]]; then
  echo "Individual quota reached. Resets in 1h0m0s." >> "${FM_AGY_RUN_LOG:-/dev/null}"
  exit 75
fi
exit 0
EOF
  chmod +x "$tdir/bin/fake-pool"

  local nm_agy="$ROOT/bin/agy-pool/nm-agy"

  # 1. First nm-agy review call from separate no-mistakes worktree opens tab, streams log, reports working -> idle
  ( cd "$tdir/nm-wt" && env PATH="$tdir/bin:$PATH" FM_HOME="$tdir" \
    FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_AGY_POOL_BIN="$tdir/bin/fake-pool" \
    FM_NM_REVIEW_MODEL="gemini-4-neon-high" \
    "$nm_agy" --model x -p "Focus findings on risks introduced by changed code" >/dev/null 2>&1 )

  local hlog
  hlog=$(cat "$herdr_log")
  assert_contains "$hlog" "tab create --workspace wH1 --label review: task_herdr_vis (gemini-4-neon-high)" \
    "nm-agy must open a tab labelled with role, model, and task"
  assert_contains "$hlog" "pane run wH1:pH1" "nm-agy must stream live run output into the tab"
  assert_contains "$hlog" "tail -n 60 -F" "tab command must stream run log read-only via tail"
  assert_contains "$hlog" "pane report-agent wH1:pH1 --source firstmate:nm-agy --agent review:gemini-4-neon-high --state working" \
    "nm-agy must report working while running"
  assert_contains "$hlog" "pane report-agent wH1:pH1 --source firstmate:nm-agy --agent review:gemini-4-neon-high --state idle" \
    "nm-agy must report idle on success"

  local log_perm
  log_perm=$(stat -c %a "$tdir/data/task_herdr_vis/nm-review.log")
  [[ "$log_perm" == "644" || "$log_perm" == "664" ]] \
    || fail "nm-review.log must be operator-readable (0644/0664), got $log_perm"
  assert_contains "$(cat "$tdir/data/task_herdr_vis/nm-review.log")" "live pool output line" \
    "run log must persist output for the Herdr tab"

  # 2. Second nm-agy review call reuses the existing tab and reports blocked on quota exhaustion
  : > "$herdr_log"
  : > "$tdir/pane_alive"
  local rc=0
  ( cd "$tdir/nm-wt" && env PATH="$tdir/bin:$PATH" FM_HOME="$tdir" \
    FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_AGY_POOL_BIN="$tdir/bin/fake-pool" FAKE_POOL_MODE=quota \
    FM_NM_REVIEW_MODEL="gemini-4-neon-high" \
    "$nm_agy" --model x -p "Focus findings on risks introduced by changed code" >/dev/null 2>&1 ) || rc=$?
  [ "$rc" -eq 75 ] || fail "nm-agy must propagate pool exit code 75, got $rc"
  hlog=$(cat "$herdr_log")
  assert_not_contains "$hlog" "tab create" "second call must reuse the existing tab"
  assert_contains "$hlog" "pane report-agent wH1:pH1 --source firstmate:nm-agy --agent review:gemini-4-neon-high --state blocked --message quota exhausted (gemini-4-neon-high)" \
    "nm-agy must report blocked with quota message on quota exhaustion"

  # 3. fm-deliver marks the task tab blocked "waiting on firstmate approval" when parked at a gate
  : > "$herdr_log"
  cat > "$tdir/bin/no-mistakes" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-}" == "axi status" ]]; then
  cat <<'TOON'
run:
  id: "01GATE"
  status: running
gate:
  step: review
  findings[1]{id}:
    f1
TOON
  exit 0
fi
exit 0
EOF
  chmod +x "$tdir/bin/no-mistakes"
  env PATH="$tdir/bin:$PATH" FM_HOME="$tdir" \
    FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_MAIN_USER="$(id -un)" FM_DELIVER_FOREGROUND=1 \
    "$DELIVER" task_herdr_vis run >/dev/null 2>&1 || true
  hlog=$(cat "$herdr_log")
  assert_contains "$hlog" "pane report-agent wH1:pH1 --source firstmate:nm-agy --agent review:gemini-4-neon-high --state blocked --message waiting on firstmate approval" \
    "fm-deliver must mark the tab blocked waiting on firstmate approval when parked at a gate"

  # 4. No-op when Herdr is absent (non-herdr backend)
  sed -i 's/^backend=herdr/backend=tmux/' "$tdir/state/task_herdr_vis.meta"
  : > "$herdr_log"
  ( cd "$tdir/nm-wt" && env PATH="$tdir/bin:$PATH" FM_HOME="$tdir" \
    FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_AGY_POOL_BIN="$tdir/bin/fake-pool" \
    "$nm_agy" --model x -p "Focus findings on risks introduced by changed code" >/dev/null 2>&1 )
  [ ! -s "$herdr_log" ] || fail "nm-agy must be a no-op for Herdr when backend != herdr, got: $(cat "$herdr_log")"

  pass "nm-agy and fm-deliver project visible read-only tabs and report-agent lifecycle in Herdr"
}

test_nm_agy_reads_role_file_without_daemon_env() {
  local sha
  sha=$(setup_fixture task_role_file)
  local tdir="$TMP_ROOT/task_role_file"
  mkdir -p "$tdir/bin" "$tdir/nm-wt" "$tdir/decoy-wt"
  printf 'backend=herdr\nherdr_workspace_id=wR1\n' >> "$tdir/state/task_role_file.meta"

  # A no-mistakes run checkout: the task branch ref sits at the builder's tip,
  # the detached run HEAD has one fix commit past it, and main is the base.
  git -C "$tdir/nm-wt" init -q -b main
  git -C "$tdir/nm-wt" config user.email "test@example.com"
  git -C "$tdir/nm-wt" config user.name "Test"
  echo "base" > "$tdir/nm-wt/base.txt"
  git -C "$tdir/nm-wt" add base.txt
  git -C "$tdir/nm-wt" commit -q -m "base commit"
  git -C "$tdir/nm-wt" checkout -q -b "fm/task_role_file"
  echo "built" > "$tdir/nm-wt/built.txt"
  git -C "$tdir/nm-wt" add built.txt
  git -C "$tdir/nm-wt" commit -q -m "builder commit"
  git -C "$tdir/nm-wt" checkout -q --detach "fm/task_role_file"
  echo "fix" > "$tdir/nm-wt/fix.txt"
  git -C "$tdir/nm-wt" add fix.txt
  git -C "$tdir/nm-wt" commit -q -m "fix commit on the run worktree"

  # An operator run from main whose only ancestor task branch is already merged
  # into main and waiting for teardown: it belongs to no firstmate task.
  git -C "$tdir/decoy-wt" init -q -b main
  git -C "$tdir/decoy-wt" config user.email "test@example.com"
  git -C "$tdir/decoy-wt" config user.name "Test"
  echo "base" > "$tdir/decoy-wt/base.txt"
  git -C "$tdir/decoy-wt" add base.txt
  git -C "$tdir/decoy-wt" commit -q -m "base commit"
  git -C "$tdir/decoy-wt" branch "fm/task_merged"
  echo "operator" > "$tdir/decoy-wt/op.txt"
  git -C "$tdir/decoy-wt" add op.txt
  git -C "$tdir/decoy-wt" commit -q -m "operator commit"
  printf 'backend=herdr\nherdr_workspace_id=wDecoy\nbranch=fm/task_merged\n' \
    > "$tdir/state/task_merged.meta"

  cat > "$tdir/state/task_role_file.nm-roles" <<'EOF'
review_model=gemini-4-neon-file
review_account=fileacct
review_from_config=1
review_fallback=gemini-4-neon-file,gemini-3.8-flash-high
fix_model=gemini-4-hydrogen-file
fix_account=
fix_from_config=1
fix_fallback=gemini-4-hydrogen-file
EOF

  cat > "$tdir/bin/fake-pool" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tdir/pool-args.log"
exit 0
EOF
  chmod +x "$tdir/bin/fake-pool"

  local herdr_log="$tdir/herdr.calls"
  cat > "$tdir/bin/herdr" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$herdr_log"
case "\${1:-} \${2:-}" in
  "tab create")
    echo '{"result":{"tab":{"tab_id":"tR1"},"root_pane":{"pane_id":"wR1:pR1"}}}'
    exit 0
    ;;
esac
exit 0
EOF
  chmod +x "$tdir/bin/herdr"

  local nm_agy="$ROOT/bin/agy-pool/nm-agy"
  local -a clean_env=(
    env -u FM_NM_REVIEW_MODEL -u FM_NM_REVIEW_ACCOUNT -u FM_NM_REVIEW_FROM_CONFIG
    -u FM_NM_FIX_MODEL -u FM_NM_FIX_ACCOUNT -u FM_NM_FIX_FROM_CONFIG
    PATH="$tdir/bin:$PATH" FM_HOME="$tdir"
    FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data"
    FM_AGY_POOL_BIN="$tdir/bin/fake-pool"
  )

  ( cd "$tdir/nm-wt" && "${clean_env[@]}" \
    "$nm_agy" --account piyushk --model wire -p "Focus findings on risks introduced by changed code" >/dev/null 2>&1 )
  ( cd "$tdir/nm-wt" && "${clean_env[@]}" \
    "$nm_agy" --account piyushk --model wire -p "Fix finding f1" >/dev/null 2>&1 )

  local pool_out review_line fix_line hlog
  pool_out=$(cat "$tdir/pool-args.log")
  review_line=$(grep 'Focus findings' <<<"$pool_out" || true)
  fix_line=$(grep 'Fix finding f1' <<<"$pool_out" || true)
  [ -n "$review_line" ] && [ -n "$fix_line" ] || fail "both role calls must reach the pool: $pool_out"
  assert_contains "$review_line" "--model gemini-4-neon-file" \
    "nm-agy must read the review model from the task role file without env"
  assert_contains "$review_line" "--account fileacct" \
    "nm-agy must read the review account from the task role file without env"
  assert_not_contains "$review_line" "piyushk" \
    "a role-file account must replace the incoming config account"
  assert_contains "$fix_line" "--model gemini-4-hydrogen-file" \
    "nm-agy must read the fix model from the task role file without env"
  assert_not_contains "$fix_line" "piyushk" \
    "an empty role-file account must strip the incoming config account so the pool can rotate"

  hlog=$(cat "$herdr_log")
  assert_contains "$hlog" "tab create --workspace wR1 --label review: task_role_file (gemini-4-neon-file)" \
    "the same branch-to-task resolver must map the detached run to the review tab"

  # The merged task branch must not claim an operator run that has no task.
  : > "$tdir/pool-args.log"
  : > "$herdr_log"
  ( cd "$tdir/decoy-wt" && "${clean_env[@]}" \
    "$nm_agy" --account piyushk --model wire -p "Focus findings on risks introduced by changed code" >/dev/null 2>&1 )
  pool_out=$(cat "$tdir/pool-args.log")
  assert_contains "$pool_out" "--account piyushk --model gemini-4-neon-medium" \
    "a run with no live task must keep the legacy model and incoming account"
  [ ! -s "$herdr_log" ] || fail "a run with no live task must not open a Herdr tab: $(cat "$herdr_log")"

  pass "nm-agy reads per-task roles without daemon env and ignores merged task branches"
}

# Stub no-mistakes whose run fails with the given text and logs every call.
make_failing_nm() {  # <tdir> <failure text>
  local tdir=$1 text=$2
  mkdir -p "$tdir/bin"
  cat > "$tdir/bin/no-mistakes" <<EOF
#!/usr/bin/env bash
cmd="\${1:-} \${2:-}"
printf '%s\n' "\$cmd" >> "$tdir/nm-calls.log"
if [[ "\$cmd" == "axi run" ]]; then
  echo "$text" >&2
  exit 1
elif [[ "\$cmd" == "axi status" ]]; then
  cat <<'TOON'
run:
  id: "01FAIL"
  status: failed
outcome: failed
TOON
fi
exit 0
EOF
  chmod +x "$tdir/bin/no-mistakes"
}

deliver_env() {  # <tdir> <args>...
  local tdir=$1
  shift
  env PATH="$tdir/bin:$PATH" FM_HOME="$tdir" \
    FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_CONFIG_OVERRIDE="$tdir/config" FM_AGY_STATE_DIR="$tdir/agy-state" \
    POOL_CONF="$tdir/pool.conf" MODELS_CONF="$tdir/models.conf" \
    FM_MAIN_USER="$(id -un)" FM_DELIVER_FOREGROUND=1 "$@"
}

test_non_code_failures_report_blocker_and_never_restart() {
  local case_name text kind expect sha tdir calls rc err
  for case_name in \
    "pushauth|fatal: could not read Username for 'https://github.com': terminal prompts disabled|push authentication" \
    "prompt|step review failed: agent review: antigravity start: fork/exec nm-agy: argument list too long|argument list too long" \
    "cap|step review failed: exit status 75: 2 pool accounts already active|pool account capacity" \
    "quota|antigravity reported error: Individual quota reached. Resets in 2h0m0s.|out of quota"; do
    kind=${case_name%%|*}
    text=${case_name#*|}; text=${text%|*}
    expect=${case_name##*|}
    sha=$(setup_fixture "task_nc_$kind")
    tdir="$TMP_ROOT/task_nc_$kind"
    mkdir -p "$tdir/config" "$tdir/agy-state"
    make_failing_nm "$tdir" "$text"
    deliver_env "$tdir" "$DELIVER" "task_nc_$kind" run >/dev/null 2>&1
    calls=$(grep -c '^axi run$' "$tdir/nm-calls.log")
    [ "$calls" -eq 1 ] || fail "$kind: run must not be restarted, saw $calls axi run calls"
    assert_contains "$(tail -n 1 "$tdir/state/task_nc_$kind.status")" "$expect" "$kind: specific blocker reported"
    assert_contains "$(tail -n 1 "$tdir/state/task_nc_$kind.status")" "blocked" "$kind: blocked state"
    rc=0
    err=$(deliver_env "$tdir" "$DELIVER" "task_nc_$kind" run 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "$kind: rerun on the same head must be refused"
    assert_contains "$err" "FM_DELIVER_RETRY=1" "$kind: refusal names the explicit retry"
    [ "$(grep -c '^axi run$' "$tdir/nm-calls.log")" -eq 1 ] || fail "$kind: refused rerun must not start a run"
    deliver_env "$tdir" FM_DELIVER_RETRY=1 "$DELIVER" "task_nc_$kind" run >/dev/null 2>&1
    [ "$(grep -c '^axi run$' "$tdir/nm-calls.log")" -eq 2 ] || fail "$kind: FM_DELIVER_RETRY=1 must allow one explicit rerun"
  done
  pass "fm-deliver reports the specific non-code blocker and never restarts the run blind"
}

test_push_auth_blocker_names_the_operator_check() {
  local sha tdir line
  sha=$(setup_fixture task_opauth)
  tdir="$TMP_ROOT/task_opauth"
  mkdir -p "$tdir/config" "$tdir/agy-state"
  make_failing_nm "$tdir" "fatal: could not read Username for 'https://github.com': terminal prompts disabled"
  deliver_env "$tdir" "$DELIVER" task_opauth run >/dev/null 2>&1
  line=$(tail -n 1 "$tdir/state/task_opauth.status")
  assert_contains "$line" "operator" "push-auth blocker must name the operator account"
  assert_contains "$line" "fm-agy-pool-setup.sh check" "push-auth blocker must name the setup check"
  assert_contains "$line" "operator push credentials" "push-auth blocker must name the exact check lines"
  pass "fm-deliver push-auth blocker names the operator credential check"
}

test_non_gemini_task_is_untouched_by_gemini_plumbing() {
  local sha tdir
  sha=$(setup_fixture task_claude)
  tdir="$TMP_ROOT/task_claude"
  mkdir -p "$tdir/config" "$tdir/agy-state" "$tdir/bin"
  printf 'harness=claude\n' >> "$tdir/state/task_claude.meta"
  cat > "$tdir/config/crew-dispatch.json" <<'JSON'
{ "roles": { "review": [ { "harness": "agy", "model": "gemini-4-neon-high" } ],
             "fix": [ { "harness": "agy", "model": "gemini-4-neon-medium" } ] } }
JSON
  cat > "$tdir/bin/no-mistakes" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-} \${2:-}" == "axi run" ]]; then
  env | grep '^FM_NM_' > "$tdir/nm-env.log" || : > "$tdir/nm-env.log"
fi
if [[ "\${1:-} \${2:-}" == "axi status" ]]; then printf 'run:\n  id: "01OK"\noutcome: passed\n'; fi
exit 0
EOF
  chmod +x "$tdir/bin/no-mistakes"
  deliver_env "$tdir" "$DELIVER" task_claude run >/dev/null 2>&1
  [ -e "$tdir/nm-env.log" ] || fail "the stub run must have been invoked"
  [ ! -s "$tdir/nm-env.log" ] || fail "a claude task must not get FM_NM_* role variables: $(cat "$tdir/nm-env.log")"
  [ ! -e "$tdir/state/task_claude.nm-roles" ] || fail "a claude task must not get a role record"

  sha=$(setup_fixture task_mixed)
  tdir="$TMP_ROOT/task_mixed"
  mkdir -p "$tdir/config" "$tdir/agy-state" "$tdir/bin"
  printf 'builder=pool\n' >> "$tdir/state/task_mixed.meta"
  cat > "$tdir/config/crew-dispatch.json" <<'JSON'
{ "roles": { "review": [ { "harness": "claude", "model": "claude-sonnet-5-5" } ] } }
JSON
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tdir/bin/no-mistakes"; chmod +x "$tdir/bin/no-mistakes"
  deliver_env "$tdir" "$DELIVER" task_mixed run >/dev/null 2>&1
  [ ! -e "$tdir/state/task_mixed.nm-roles" ] || fail "non-agy role entries must not reach the Gemini role record"
  pass "non-Gemini tasks and non-agy role entries are untouched by the Gemini plumbing"
}

test_nm_agy_defaults_are_neon_medium_without_record() {
  local tdir="$TMP_ROOT/nm_defaults"
  mkdir -p "$tdir/bin" "$tdir/state" "$tdir/wt"
  git -C "$tdir/wt" init -q -b scratch
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/pool-args.log"\n' "$tdir" > "$tdir/bin/fake-pool"
  chmod +x "$tdir/bin/fake-pool"
  ( cd "$tdir/wt" && FM_HOME="$tdir" FM_AGY_POOL_BIN="$tdir/bin/fake-pool" \
      "$ROOT/bin/agy-pool/nm-agy" -p "Focus findings on risks introduced by changed code" >/dev/null 2>&1
    FM_HOME="$tdir" FM_AGY_POOL_BIN="$tdir/bin/fake-pool" \
      "$ROOT/bin/agy-pool/nm-agy" -p "Fix finding f1" >/dev/null 2>&1 )
  [ "$(grep -c -- '--model gemini-4-neon-medium' "$tdir/pool-args.log")" -eq 2 ] \
    || fail "review and fix must both default to gemini-4-neon-medium: $(cat "$tdir/pool-args.log")"
  ! grep -q hydrogen "$tdir/pool-args.log" || fail "Hydrogen must not be a default"
  pass "nm-agy defaults review and fix to gemini-4-neon-medium for runs belonging to no task"
}

test_blocker_kind_follows_pool_exit_75_cause() {
  local case_name text kind expect tdir status_line
  for case_name in \
    "allex|[fm-agy-pool] ERROR: All eligible accounts for model 'm' are exhausted.${NL}step review failed: exit status 75|out of quota" \
    "owner|[fm-agy-pool] ERROR: account 'a' owns conversation 'c' but cannot take the call now; not running it elsewhere.${NL}step fix failed: exit status 75|owns this agent conversation" \
    "capbare|step review failed: exit status 75|pool account capacity"; do
    kind=${case_name%%|*}
    text=${case_name#*|}; text=${text%|*}
    expect=${case_name##*|}
    setup_fixture "task_x75_$kind" >/dev/null
    tdir="$TMP_ROOT/task_x75_$kind"
    mkdir -p "$tdir/config" "$tdir/agy-state"
    make_failing_nm "$tdir" "$text"
    deliver_env "$tdir" "$DELIVER" "task_x75_$kind" run >/dev/null 2>&1
    status_line=$(tail -n 1 "$tdir/state/task_x75_$kind.status")
    assert_contains "$status_line" "$expect" "$kind: blocker names the real cause of exit 75"
  done
  pass "exit status 75 is classified by its cause: quota, conversation owner, then capacity"
}

test_run_passes_base_branch_from_meta() {
  local tdir="$TMP_ROOT/task_base"
  setup_fixture task_base >/dev/null
  printf 'base_branch=release-x\n' >> "$tdir/state/task_base.meta"
  mkdir -p "$tdir/bin" "$tdir/config" "$tdir/agy-state"
  cat > "$tdir/bin/no-mistakes" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-} \${2:-}" == "axi run" ]]; then
  printf '%s\n' "\$*" >> "$tdir/run-argv.log"
elif [[ "\${1:-} \${2:-}" == "axi status" ]]; then
  printf 'run:\n  id: "01B"\n  status: completed\noutcome: passed\nbranch_sync:\n  next_action:\n    command: "no-mistakes axi sync"\n'
fi
exit 0
EOF
  chmod +x "$tdir/bin/no-mistakes"
  deliver_env "$tdir" "$DELIVER" task_base run >/dev/null 2>&1 || true
  assert_contains "$(cat "$tdir/run-argv.log")" "--base-branch release-x" "meta base_branch must reach axi run"
  pass "run passes the task's base_branch to no-mistakes"
}

test_nm_agy_detects_review_role_from_stdin_prompt() {
  local tdir="$TMP_ROOT/nm_stdin"
  mkdir -p "$tdir/bin" "$tdir/logs" "$tdir/state" "$tdir/data"
  cat > "$tdir/bin/fake-pool" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tdir/pool-args.log"
cat >> "$tdir/pool-stdin.log"
exit 0
EOF
  chmod +x "$tdir/bin/fake-pool"
  local prompt review fix
  prompt='{"event":"user","message":{"role":"user","content":[{"type":"text","text":"Focus findings on risks introduced by changed code"}]}}'
  review=$(printf '%s\n' "$prompt" | env FM_HOME="$tdir" FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_NM_HERDR_TAB=off FM_NM_REVIEW_MODEL=gemini-4-neon-high FM_NM_FIX_MODEL=gemini-4-hydrogen-high \
    FM_AGY_POOL_BIN="$tdir/bin/fake-pool" "$ROOT/bin/agy-pool/nm-agy" --print= --input-format stream-json 2>&1)
  fix=$(printf '%s\n' '{"event":"user","message":{"content":[{"type":"text","text":"Fix finding f1"}]}}' | env FM_HOME="$tdir" FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_NM_HERDR_TAB=off FM_NM_REVIEW_MODEL=gemini-4-neon-high FM_NM_FIX_MODEL=gemini-4-hydrogen-high \
    FM_AGY_POOL_BIN="$tdir/bin/fake-pool" "$ROOT/bin/agy-pool/nm-agy" --print= --input-format stream-json 2>&1)
  assert_contains "$review" "role=review model=gemini-4-neon-high" "review prompt on stdin selects the review role"
  assert_contains "$fix" "role=fix model=gemini-4-hydrogen-high" "other stdin prompts select the fix role"
  assert_contains "$(cat "$tdir/pool-stdin.log")" "Focus findings on risks" "the pool still receives the stdin prompt"
  assert_contains "$(cat "$tdir/pool-stdin.log")" "Fix finding f1" "the pool receives the fix prompt too"
  pass "nm-agy detects the review role from a stdin prompt and forwards stdin intact"
}

test_background_failover_restart_keeps_base_branch() {
  setup_fixture task_bgfail >/dev/null
  local tdir="$TMP_ROOT/task_bgfail" i
  printf 'base_branch=release-x\n' >> "$tdir/state/task_bgfail.meta"
  mkdir -p "$tdir/bin" "$tdir/config" "$tdir/agy-state"
  cat > "$tdir/config/crew-dispatch.json" <<'JSON'
{"roles":{"review":[{"harness":"agy","model":"gemini-4-neon-high"},{"harness":"agy","model":"gemini-3.8-flash-high"}]}}
JSON
  printf 'acct1\n' > "$tdir/pool.conf"
  printf '*neon* acct1\n' > "$tdir/models.conf"
  cat > "$tdir/bin/no-mistakes" <<EOF
#!/usr/bin/env bash
cmd="\${1:-} \${2:-}"
if [[ "\$cmd" == "axi run" ]]; then
  printf '%s|model=%s\n' "\$*" "\${FM_NM_REVIEW_MODEL:-}" >> "$tdir/run-argv.log"
  if [[ "\${FM_NM_REVIEW_MODEL:-}" == "gemini-4-neon-high" ]]; then
    echo "antigravity exited pid=1 error=antigravity reported error: Individual quota reached. Resets in 2h0m0s." >&2
    printf '{"user":"acct1","window_start":1000,"reset_at":9999999999,"used_sec":10,"budget_sec":5400,"exhausted":true}\n' > "$tdir/agy-state/acct1.state.json"
    : > "$tdir/failed_once"
    exit 1
  fi
  exit 0
elif [[ "\$cmd" == "axi abort" ]]; then
  rm -f "$tdir/failed_once"; : > "$tdir/aborted"
elif [[ "\$cmd" == "axi sync" ]]; then
  : > "$tdir/recovered"
elif [[ "\$cmd" == "axi status" ]]; then
  if [[ -f "$tdir/failed_once" ]]; then
    printf 'run:\n  id: "1"\n  status: failed\noutcome: failed\nbranch_sync:\n  state: pipeline_owned\n  next_action:\n    command: "no-mistakes axi sync --recover"\n'
  elif [[ -f "$tdir/aborted" && ! -f "$tdir/recovered" ]]; then
    printf 'branch_sync:\n  state: pipeline_owned\n  next_action:\n    command: "no-mistakes axi sync --recover"\n'
  else
    printf 'run:\n  id: "2"\n  status: completed\noutcome: passed\nbranch_sync:\n  next_action:\n    command: "no-mistakes axi sync"\n'
  fi
fi
exit 0
EOF
  chmod +x "$tdir/bin/no-mistakes"
  env PATH="$tdir/bin:$PATH" FM_HOME="$tdir" \
    FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_CONFIG_OVERRIDE="$tdir/config" FM_AGY_STATE_DIR="$tdir/agy-state" \
    POOL_CONF="$tdir/pool.conf" MODELS_CONF="$tdir/models.conf" \
    FM_MAIN_USER="$(id -un)" FM_DELIVER_TAB=off \
    "$DELIVER" task_bgfail run >/dev/null 2>&1
  for i in $(seq 1 100); do
    [ "$(grep -c 'axi run' "$tdir/run-argv.log" 2>/dev/null || echo 0)" -ge 2 ] && break
    sleep 0.2
  done
  assert_contains "$(grep 'model=gemini-3.8-flash-high' "$tdir/run-argv.log")" "--base-branch release-x" \
    "the failover restart on the background path must keep the delivery base branch"
  pass "background failover restart keeps --base-branch"
}

test_respond_on_running_run_writes_no_blocked_status() {
  setup_fixture task_resp_run >/dev/null
  local tdir="$TMP_ROOT/task_resp_run" i
  mkdir -p "$tdir/bin"
  cat > "$tdir/bin/no-mistakes" <<EOF
#!/usr/bin/env bash
cmd="\${1:-} \${2:-}"
if [[ "\$cmd" == "axi status" ]]; then
  n=\$(cat "$tdir/status-calls" 2>/dev/null || echo 0)
  n=\$((n + 1))
  printf '%s' "\$n" > "$tdir/status-calls"
  if [[ "\$n" -le 2 ]]; then
    printf 'run:\n  id: "1"\n  status: running\n'
  else
    printf 'run:\n  id: "1"\n  status: completed\noutcome: passed\nbranch_sync:\n  next_action:\n    command: "no-mistakes axi sync"\n'
  fi
fi
exit 0
EOF
  chmod +x "$tdir/bin/no-mistakes"
  env PATH="$tdir/bin:$PATH" FM_HOME="$tdir" \
    FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_MAIN_USER="$(id -un)" \
    "$DELIVER" task_resp_run respond approve >/dev/null 2>&1
  for i in $(seq 1 100); do
    grep -q 'Run still executing after respond' "$tdir/data/task_resp_run/drive.log" 2>/dev/null &&
      [ "$(cat "$tdir/status-calls" 2>/dev/null || echo 0)" -ge 3 ] && break
    sleep 0.2
  done
  sleep 1
  assert_contains "$(cat "$tdir/data/task_resp_run/drive.log")" "Run still executing after respond" \
    "respond must hand a still-running run to the background watcher"
  assert_not_contains "$(cat "$tdir/state/task_resp_run.status")" "blocked" \
    "answering a gate while the run keeps executing must not write a blocked record"
  pass "respond on a still-running run writes no blocked status"
}

test_respond_creates_missing_drive_log_quietly() {
  setup_fixture task_nodrive >/dev/null
  local tdir="$TMP_ROOT/task_nodrive" out
  mkdir -p "$tdir/bin"
  cat > "$tdir/bin/no-mistakes" <<'EOF'
#!/usr/bin/env bash
cmd="${1:-} ${2:-}"
if [[ "$cmd" == "axi status" ]]; then
  printf 'run:\n  id: "1"\n  status: completed\noutcome: passed\n'
fi
exit 0
EOF
  chmod +x "$tdir/bin/no-mistakes"
  [ ! -e "$tdir/data/task_nodrive/drive.log" ] || fail "fixture must start without a drive log"
  out=$(deliver_env "$tdir" "$DELIVER" task_nodrive respond approve 2>&1)
  assert_not_contains "$out" "No such file or directory" \
    "a fresh task must not emit a bash redirection error for a missing drive log"
  [ -f "$tdir/data/task_nodrive/drive.log" ] || fail "respond must create the drive log"
  pass "respond creates a missing drive log without a bash error"
}

test_blocker_ignores_test_step_output() {
  setup_fixture task_testlog >/dev/null
  local tdir="$TMP_ROOT/task_testlog" nmhome="$TMP_ROOT/task_testlog/nmhome"
  mkdir -p "$tdir/config" "$tdir/agy-state" "$nmhome/logs/RUN1"
  printf 'FAIL TestLogin: Authentication failed\nPermission denied (publickey)\n' > "$nmhome/logs/RUN1/test.log"
  mkdir -p "$tdir/bin"
  cat > "$tdir/bin/no-mistakes" <<'EOF'
#!/usr/bin/env bash
cmd="${1:-} ${2:-}"
if [[ "$cmd" == "axi status" ]]; then
  printf 'run:\n  id: "RUN1"\n  status: failed\noutcome: failed\n'
fi
exit 0
EOF
  chmod +x "$tdir/bin/no-mistakes"
  NM_HOME="$nmhome" deliver_env "$tdir" "$DELIVER" task_testlog run >/dev/null 2>&1
  assert_not_contains "$(tail -n 1 "$tdir/state/task_testlog.status")" "push authentication" \
    "credential-looking text in the project's test output is a code failure, not a push blocker"
  [ ! -e "$tdir/state/task_testlog.nm-blocker" ] || fail "no blocker record may be written for test-step output"
  pass "blocker classification ignores project test output"
}

test_failover_triggers_on_pool_quota_notice_in_review_log() {
  setup_fixture task_poolnotice >/dev/null
  local tdir="$TMP_ROOT/task_poolnotice" nmhome="$TMP_ROOT/task_poolnotice/nmhome"
  mkdir -p "$tdir/bin" "$tdir/config" "$tdir/agy-state" "$nmhome/logs/RUNQ"
  cat > "$tdir/config/crew-dispatch.json" <<'JSON'
{"roles":{"review":[{"harness":"agy","model":"gemini-4-neon-high","account":"acct1"},{"harness":"agy","model":"gemini-3.8-flash-high"}]}}
JSON
  printf "error: Individual quota reached\n[fm-agy-pool] Account 'acct1' hit quota exhaustion; marked exhausted until 1.\n" > "$nmhome/logs/RUNQ/review.log"
  cat > "$tdir/bin/no-mistakes" <<EOF
#!/usr/bin/env bash
cmd="\${1:-} \${2:-}"
if [[ "\$cmd" == "axi run" ]]; then
  printf '%s\n' "\${FM_NM_REVIEW_MODEL:-}" >> "$tdir/run-models.log"
  [[ "\${FM_NM_REVIEW_MODEL:-}" == "gemini-4-neon-high" ]] && : > "$tdir/failed_once"
  exit 0
elif [[ "\$cmd" == "axi status" ]]; then
  if [[ -f "$tdir/failed_once" && ! -f "$tdir/aborted" ]]; then
    printf 'run:\n  id: "RUNQ"\n  status: failed\noutcome: failed\n'
  else
    printf 'run:\n  id: "RUNP"\n  status: completed\noutcome: passed\nbranch_sync:\n  next_action:\n    command: "no-mistakes axi sync"\n'
  fi
elif [[ "\$cmd" == "axi abort" ]]; then
  : > "$tdir/aborted"
fi
exit 0
EOF
  chmod +x "$tdir/bin/no-mistakes"
  NM_HOME="$nmhome" deliver_env "$tdir" "$DELIVER" task_poolnotice run >/dev/null 2>&1
  assert_contains "$(cat "$tdir/run-models.log")" "gemini-3.8-flash-high" \
    "the pool's own quota notice in review.log must trigger failover to the next model"
  pass "failover triggers on the pool quota notice in review.log"
}

test_no_failover_after_pool_rotation_recovered() {
  setup_fixture task_rotated >/dev/null
  local tdir="$TMP_ROOT/task_rotated" nmhome="$TMP_ROOT/task_rotated/nmhome"
  mkdir -p "$tdir/bin" "$tdir/config" "$tdir/agy-state" "$nmhome/logs/RUNR"
  cat > "$tdir/config/crew-dispatch.json" <<'JSON'
{"roles":{"review":[{"harness":"agy","model":"gemini-4-neon-high"},{"harness":"agy","model":"gemini-3.8-flash-high"}]}}
JSON
  printf "[fm-agy-pool] Account 'acct1' hit quota exhaustion; marked exhausted until 1.\n[fm-agy-pool] Rotating away from exhausted account 'acct1' to next eligible account...\n" > "$nmhome/logs/RUNR/review.log"
  printf 'fatal: could not read Username for https://github.com\n' > "$nmhome/logs/RUNR/push.log"
  cat > "$tdir/bin/no-mistakes" <<EOF
#!/usr/bin/env bash
cmd="\${1:-} \${2:-}"
if [[ "\$cmd" == "axi run" ]]; then
  printf '%s\n' "\${FM_NM_REVIEW_MODEL:-}" >> "$tdir/run-models.log"
elif [[ "\$cmd" == "axi status" ]]; then
  printf 'run:\n  id: "RUNR"\n  status: failed\noutcome: failed\n'
fi
exit 0
EOF
  chmod +x "$tdir/bin/no-mistakes"
  NM_HOME="$nmhome" deliver_env "$tdir" "$DELIVER" task_rotated run >/dev/null 2>&1
  [ "$(grep -c . "$tdir/run-models.log")" -eq 1 ] || fail "a quota hit the pool already rotated past must not restart the run: $(cat "$tdir/run-models.log")"
  assert_contains "$(tail -n 1 "$tdir/state/task_rotated.status")" "push authentication" \
    "the real push failure must be reported as the blocker"
  pass "no failover after the pool recovered by rotating accounts"
}

test_failover_keeps_role_line_across_rotation() {
  setup_fixture task_rolekeep >/dev/null
  local tdir="$TMP_ROOT/task_rolekeep" nmhome="$TMP_ROOT/task_rolekeep/nmhome"
  mkdir -p "$tdir/bin" "$tdir/config" "$tdir/agy-state" "$nmhome/logs/RUNF"
  cat > "$tdir/config/crew-dispatch.json" <<'JSON'
{"roles":{"review":[{"harness":"agy","model":"gemini-4-neon-high"},{"harness":"agy","model":"gemini-3.8-flash-high"}],"fix":[{"harness":"agy","model":"gemini-4-hydrogen-high"},{"harness":"agy","model":"gemini-3.8-flash-medium"}]}}
JSON
  printf "[nm-agy] 2026-01-01T00:00:00Z cwd=/x role=fix model=gemini-4-hydrogen-high\n[fm-agy-pool] Account 'acct1' hit quota exhaustion; marked exhausted until 1.\n[fm-agy-pool] Rotating away from exhausted account 'acct1' to next eligible account...\n[fm-agy-pool] ERROR: All eligible accounts for model 'gemini-4-hydrogen-high' are exhausted.\n" > "$nmhome/logs/RUNF/review.log"
  cat > "$tdir/bin/no-mistakes" <<EOF
#!/usr/bin/env bash
cmd="\${1:-} \${2:-}"
if [[ "\$cmd" == "axi run" ]]; then
  printf 'review=%s fix=%s\n' "\${FM_NM_REVIEW_MODEL:-}" "\${FM_NM_FIX_MODEL:-}" >> "$tdir/run-models.log"
  [[ "\${FM_NM_FIX_MODEL:-}" == "gemini-4-hydrogen-high" ]] && : > "$tdir/failed_once"
elif [[ "\$cmd" == "axi status" ]]; then
  if [[ -f "$tdir/failed_once" && ! -f "$tdir/aborted" ]]; then
    printf 'run:\n  id: "RUNF"\n  status: failed\noutcome: failed\n'
  else
    printf 'run:\n  id: "RUNP"\n  status: completed\noutcome: passed\nbranch_sync:\n  next_action:\n    command: "no-mistakes axi sync"\n'
  fi
elif [[ "\$cmd" == "axi abort" ]]; then
  : > "$tdir/aborted"
fi
exit 0
EOF
  chmod +x "$tdir/bin/no-mistakes"
  NM_HOME="$nmhome" deliver_env "$tdir" "$DELIVER" task_rolekeep run >/dev/null 2>&1
  assert_contains "$(tail -n 1 "$tdir/run-models.log")" "fix=gemini-3.8-flash-medium" \
    "the fix role named by the nm-agy line must advance even after a rotation line"
  assert_contains "$(tail -n 1 "$tdir/run-models.log")" "review=gemini-4-neon-high" "the review role must stay put"
  pass "failover keeps the nm-agy role line across a pool rotation"
}

test_respond_nonzero_after_run_advanced_drives_next_gate() {
  local sha
  sha=$(setup_fixture task_respond_adv)
  local tdir="$TMP_ROOT/task_respond_adv"
  mkdir -p "$tdir/bin"
  # respond exits 1 although the run moved on; the next status reads show it running, then parked at document.
  cat > "$tdir/bin/no-mistakes" <<EOF2
#!/usr/bin/env bash
if [[ "\${1:-} \${2:-}" == "axi respond" ]]; then
  exit 1
elif [[ "\${1:-} \${2:-}" == "axi run" ]]; then
  exit 0
elif [[ "\${1:-} \${2:-}" == "axi status" ]]; then
  n=\$(cat "$tdir/n" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$tdir/n"
  if (( n <= 2 )); then
    printf 'run:\n  id: "01R"\n  status: running\n'
  else
    printf 'run:\n  id: "01R"\n  status: awaiting_approval\ngate:\n  step: document\n  summary: 2 ask-user findings\n'
  fi
  exit 0
fi
exit 0
EOF2
  chmod +x "$tdir/bin/no-mistakes"
  echo "needs-decision [at=100] [key=gate-review]: review findings" >> "$tdir/state/task_respond_adv.status"

  env PATH="$tdir/bin:$PATH" FM_HOME="$tdir" \
    FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_MAIN_USER="$(id -un)" FM_DELIVER_FOREGROUND=1 FM_DELIVER_REATTACH_PAUSE=0 \
    "$DELIVER" task_respond_adv respond --action approve >/dev/null 2>&1 || true

  local sfile="$tdir/state/task_respond_adv.status"
  grep -q 'resolved.*\[key=gate-review\]' "$sfile" || fail "the answered gate must close once the run moved past it: $(cat "$sfile")"
  assert_contains "$(tail -n 1 "$sfile")" "key=gate-document" "the next gate must surface as its own needs-decision"

  pass "a respond that exits nonzero after the run advanced closes the old gate and surfaces the next one"
}

test_checks_passed_with_pr_is_done_and_reattach_is_paced() {
  local sha
  sha=$(setup_fixture task_green)
  local tdir="$TMP_ROOT/task_green"
  mkdir -p "$tdir/bin"
  cat > "$tdir/bin/no-mistakes" <<EOF2
#!/usr/bin/env bash
if [[ "\${1:-} \${2:-}" == "axi run" ]]; then
  echo "run-call" >> "$tdir/calls.log"
  if [[ -n "\${GREEN:-}" ]] && (( \$(wc -l < "$tdir/calls.log") >= 2 )); then
    printf 'outcome: checks-passed\npr: https://example.test/o/r/pull/7\n'
  fi
elif [[ "\${1:-} \${2:-}" == "axi status" ]]; then
  printf 'run:\n  id: "01R"\n  status: running\n'
fi
exit 0
EOF2
  chmod +x "$tdir/bin/no-mistakes"

  env PATH="$tdir/bin:$PATH" FM_HOME="$tdir" \
    FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_MAIN_USER="$(id -un)" FM_DELIVER_FOREGROUND=1 FM_DELIVER_REATTACH_PAUSE=0 GREEN=1 \
    "$DELIVER" task_green run >/dev/null 2>&1 || true
  local last
  last=$(tail -n 1 "$tdir/state/task_green.status")
  assert_contains "$last" "done" "checks-passed with a PR must be reported done"
  assert_contains "$last" "https://example.test/o/r/pull/7" "the done line must carry the PR URL"
  assert_not_contains "$last" "blocked" "a green PR must never be reported blocked"

  # Never green: the reattach budget must be paced, not spent in an instant.
  rm -f "$tdir/calls.log"
  local t0=$SECONDS
  env PATH="$tdir/bin:$PATH" FM_HOME="$tdir" \
    FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_MAIN_USER="$(id -un)" FM_DELIVER_FOREGROUND=1 FM_DELIVER_REATTACH_MAX=2 FM_DELIVER_REATTACH_PAUSE=1 \
    "$DELIVER" task_green run >/dev/null 2>&1 || true
  [ $((SECONDS - t0)) -ge 2 ] || fail "reattaches must back off between attempts"
  assert_contains "$(tail -n 1 "$tdir/state/task_green.status")" "blocked" "an unfinished run still reports in-progress after the paced budget"

  pass "checks-passed with a PR is done, and reattaches back off"
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
  test_respond_keeps_gate_open_when_respond_fails \
  test_respond_closes_every_named_gate_key \
  test_run_intent_includes_firstmate_decisions \
  test_run_opens_progress_tab_on_herdr \
  test_run_exits_finished_pool_builder_once \
  test_run_keeps_pool_builder_with_open_decision_or_other_shape \
  test_run_reattaches_while_run_in_progress \
  test_respond_normalizes_supervisor_forms \
  test_run_resolves_roles_and_nm_agy_consumes_them \
  test_quota_failover_restarts_with_next_role_model \
  test_quota_words_in_agent_answer_do_not_fail_over \
  test_herdr_visibility_for_nm_agy_and_gate_park \
  test_nm_agy_reads_role_file_without_daemon_env \
  test_non_code_failures_report_blocker_and_never_restart \
  test_push_auth_blocker_names_the_operator_check \
  test_non_gemini_task_is_untouched_by_gemini_plumbing \
  test_nm_agy_defaults_are_neon_medium_without_record \
  test_blocker_kind_follows_pool_exit_75_cause \
  test_run_passes_base_branch_from_meta \
  test_nm_agy_detects_review_role_from_stdin_prompt \
  test_background_failover_restart_keeps_base_branch \
  test_respond_on_running_run_writes_no_blocked_status \
  test_respond_creates_missing_drive_log_quietly \
  test_blocker_ignores_test_step_output \
  test_failover_triggers_on_pool_quota_notice_in_review_log \
  test_no_failover_after_pool_rotation_recovered \
  test_failover_keeps_role_line_across_rotation \
  test_respond_nonzero_after_run_advanced_drives_next_gate \
  test_checks_passed_with_pr_is_done_and_reattach_is_paced
