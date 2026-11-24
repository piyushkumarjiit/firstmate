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

  # Absent roles preserves legacy defaults and incoming --account
  rm -f "$tdir/config/crew-dispatch.json" "$tdir/pool-args.log" "$tdir/env.log"
  env PATH="$tdir/bin:$PATH" FM_HOME="$tdir" \
    FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_CONFIG_OVERRIDE="$tdir/config" FM_AGY_STATE_DIR="$tdir/agy-state" \
    FM_MAIN_USER="$(id -un)" FM_DELIVER_FOREGROUND=1 \
    "$DELIVER" task_roles run >/dev/null 2>&1 || true
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
  # ~/.no-mistakes/worktrees/...): the branch ref exists in the run repo, but the
  # worktree itself is checked out at a detached HEAD, as no-mistakes does.
  git -C "$tdir/nm-wt" init -q
  git -C "$tdir/nm-wt" config user.email "test@example.com"
  git -C "$tdir/nm-wt" config user.name "Test"
  echo "x" > "$tdir/nm-wt/f.txt"
  git -C "$tdir/nm-wt" add f.txt
  git -C "$tdir/nm-wt" commit -q -m "nm mirror commit"
  git -C "$tdir/nm-wt" branch "fm/task_herdr_vis"
  git -C "$tdir/nm-wt" checkout -q --detach HEAD
  [ "$(git -C "$tdir/nm-wt" rev-parse --abbrev-ref HEAD)" = "HEAD" ] \
    || fail "fixture must be a detached-HEAD no-mistakes worktree"

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
  test_run_reattaches_while_run_in_progress \
  test_respond_normalizes_supervisor_forms \
  test_run_resolves_roles_and_nm_agy_consumes_them \
  test_quota_failover_restarts_with_next_role_model \
  test_quota_words_in_agent_answer_do_not_fail_over \
  test_herdr_visibility_for_nm_agy_and_gate_park
