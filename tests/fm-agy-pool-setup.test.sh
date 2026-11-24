#!/usr/bin/env bash
# bin/fm-agy-pool-setup.sh: read-only check mode, idempotent apply mode, and
# root-needing steps printing commands. Uses throwaway configs, the current
# user as the sole "pool account", and a stub sudo, so nothing real is touched.
set -u

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SETUP="$ROOT/bin/fm-agy-pool-setup.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-pool-setup)
ME=$(id -un)

mkdir -p "$TMP_ROOT/nm/worktrees" "$TMP_ROOT/gh" "$TMP_ROOT/bin" "$TMP_ROOT/poolhome"
printf '# pool\n%s\n' "$ME" > "$TMP_ROOT/pool.conf"
printf '*neon* %s\n*hydrogen* %s\n' "$ME" "$ME" > "$TMP_ROOT/models.conf"
cat > "$TMP_ROOT/nm/config.yaml" <<'EOF'
agent_path_override:
  antigravity: /x/bin/agy-pool/nm-agy
review_agents:
  reviewer:
    agent: antigravity
EOF
# Stub sudo: "stub -u <user> cmd..." runs cmd with a private HOME.
cat > "$TMP_ROOT/bin/stubsudo" <<EOF
#!/usr/bin/env bash
shift 2
unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT
HOME="$TMP_ROOT/poolhome" exec "\$@"
EOF
chmod +x "$TMP_ROOT/bin/stubsudo"

run_setup() {
  env POOL_CONF="$TMP_ROOT/pool.conf" MODELS_CONF="${MODELS:-$TMP_ROOT/models.conf}" \
    FM_NM_WORKTREES="$TMP_ROOT/nm/worktrees" FM_NM_CONFIG="$TMP_ROOT/nm/config.yaml" \
    FM_AGY_USAGE_LOG="$TMP_ROOT/usage.jsonl" FM_AGY_STATE_DIR="$TMP_ROOT/state" \
    FM_GH_CONFIG_DIR="$TMP_ROOT/gh" FM_GH_BIN=/usr/bin/gh \
    FM_SETUP_SUDO="${SUDOCMD:-$TMP_ROOT/bin/stubsudo}" bash "$SETUP" "$@" 2>&1
}

if ! command -v setfacl >/dev/null 2>&1 || ! setfacl -m "u:$ME:rwx" "$TMP_ROOT/nm/worktrees" 2>/dev/null; then
  pass "skipped: ACLs unsupported here"
  echo 1..1
  echo FM_TEST_COMPLETE
  exit 0
fi
setfacl -b "$TMP_ROOT/nm/worktrees"

test_check_is_read_only_and_reports_missing() {
  local out rc
  out=$(run_setup check); rc=$?
  [[ $rc -eq 1 ]] || { fail "check should exit 1 when items are missing (rc=$rc): $out"; }
  grep -q 'MISSING ACL (access + default)' <<<"$out" || { fail "missing ACL not reported: $out"; }
  grep -q 'MISSING git HTTPS credential helper' <<<"$out" || { fail "missing helper not reported: $out"; }
  [[ ! -e "$TMP_ROOT/poolhome/.gitconfig" ]] || { fail "check wrote a gitconfig"; }
  getfacl -p "$TMP_ROOT/nm/worktrees" | grep -q "^user:$ME:" && { fail "check changed ACLs"; }
  pass "check mode is read-only and reports missing items"
}

test_apply_is_idempotent_and_check_then_passes() {
  local out rc
  out=$(run_setup apply); rc=$?
  [[ $rc -eq 0 ]] || { fail "apply rc=$rc: $out"; }
  grep -q 'fixed   ACL (access + default)' <<<"$out" || { fail "apply did not set ACL: $out"; }
  grep -q 'auth git-credential' "$TMP_ROOT/poolhome/.gitconfig" || { fail "helper not written"; }
  out=$(run_setup apply)
  grep -q '^fixed' <<<"$out" && { fail "second apply changed things: $out"; }
  out=$(run_setup check); rc=$?
  [[ $rc -eq 0 ]] || { fail "check after apply rc=$rc: $out"; }
  [[ $(grep -c 'auth git-credential' "$TMP_ROOT/poolhome/.gitconfig") -eq 1 ]] || { fail "helper duplicated"; }
  pass "apply is idempotent and check passes afterwards"
}

test_root_steps_print_commands() {
  local out rc
  MODELS="$TMP_ROOT/absent-models.conf" out=$(MODELS="$TMP_ROOT/absent-models.conf" run_setup check); rc=$?
  [[ $rc -eq 1 ]] || { fail "missing models conf should fail check"; }
  grep -q 'run: sudo install -D' <<<"$out" || { fail "root command not printed: $out"; }
  out=$(SUDOCMD=none run_setup apply)
  grep -q "sudo -u $ME git config --global" <<<"$out" || { fail "per-account command not printed when sudo disabled: $out"; }
  pass "root-needing steps print exact commands"
}

test_nm_config_never_edited() {
  local before after
  before=$(cksum < "$TMP_ROOT/nm/config.yaml")
  run_setup apply >/dev/null
  after=$(cksum < "$TMP_ROOT/nm/config.yaml")
  [[ "$before" == "$after" ]] || { fail "no-mistakes config was modified"; }
  run_setup check | grep -q 'review_agents use antigravity' || { fail "reviewer config not reported"; }
  pass "no-mistakes config is reported, never edited"
}

test_unreachable_ancestor_is_not_reported_ok() {
  local out rc
  cat > "$TMP_ROOT/bin/blocksudo" <<EOF
#!/usr/bin/env bash
shift 2
if [[ "\$1" == test && "\$2" == -x ]]; then exit 1; fi
HOME="$TMP_ROOT/poolhome" exec "\$@"
EOF
  chmod +x "$TMP_ROOT/bin/blocksudo"
  out=$(SUDOCMD="$TMP_ROOT/bin/blocksudo" run_setup check); rc=$?
  [[ $rc -eq 1 ]] || { fail "check must fail when the pool account cannot traverse to the worktrees (rc=$rc): $out"; }
  grep -q "ROOT    $ME cannot traverse to worktrees directory" <<<"$out" || { fail "unreachable worktrees not reported: $out"; }
  grep -q "sudo setfacl -m u:${ME}:--x" <<<"$out" || { fail "no ancestor traverse command printed: $out"; }
  pass "check reports a pool account that cannot traverse to the worktrees"
}

fm_test_run test_check_is_read_only_and_reports_missing test_apply_is_idempotent_and_check_then_passes test_root_steps_print_commands test_nm_config_never_edited test_unreachable_ancestor_is_not_reported_ok
