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
# Stub gh: "auth status" succeeds only while the marker file exists.
cat > "$TMP_ROOT/bin/gh" <<EOF
#!/usr/bin/env bash
[ "\$1 \$2 \$3 \$4" = "auth status --hostname github.com" ] && [ -e "$TMP_ROOT/gh-logged-in" ]
EOF
chmod +x "$TMP_ROOT/bin/gh"
touch "$TMP_ROOT/gh-logged-in"
# The operator's own HOME is isolated so its git config is the test's to set.
mkdir -p "$TMP_ROOT/ophome"
printf '[credential]\n\thelper = store\n' > "$TMP_ROOT/ophome/.gitconfig"
printf 'https://user:token@github.com\n' > "$TMP_ROOT/ophome/.git-credentials"

run_setup() {
  env -u GIT_CONFIG_GLOBAL POOL_CONF="$TMP_ROOT/pool.conf" MODELS_CONF="${MODELS:-$TMP_ROOT/models.conf}" \
    FM_NM_WORKTREES="$TMP_ROOT/nm/worktrees" FM_NM_CONFIG="$TMP_ROOT/nm/config.yaml" \
    FM_AGY_USAGE_LOG="$TMP_ROOT/usage.jsonl" FM_AGY_STATE_DIR="$TMP_ROOT/state" \
    FM_GH_CONFIG_DIR="$TMP_ROOT/gh" FM_GH_BIN="$TMP_ROOT/bin/gh" HOME="$TMP_ROOT/ophome" \
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

test_operator_push_credentials_are_checked() {
  local out rc
  out=$(run_setup check); rc=$?
  grep -q 'ok      operator push credentials: gh login' <<<"$out" || { fail "operator gh login not confirmed: $out"; }
  grep -q 'ok      operator push credentials: git credential helper' <<<"$out" || { fail "operator helper not confirmed: $out"; }
  rm -f "$TMP_ROOT/gh-logged-in"
  out=$(run_setup check); rc=$?
  touch "$TMP_ROOT/gh-logged-in"
  [[ $rc -eq 1 ]] || { fail "check must fail without an operator gh login (rc=$rc): $out"; }
  grep -q 'MISSING operator push credentials: no working gh login' <<<"$out" || { fail "missing operator login not reported: $out"; }
  mv "$TMP_ROOT/ophome/.gitconfig" "$TMP_ROOT/ophome/.gitconfig.off"
  out=$(run_setup check); rc=$?
  mv "$TMP_ROOT/ophome/.gitconfig.off" "$TMP_ROOT/ophome/.gitconfig"
  [[ $rc -eq 1 ]] || { fail "check must fail without an operator credential helper (rc=$rc): $out"; }
  grep -q 'MISSING operator push credentials: no git credential for github.com' <<<"$out" || { fail "missing operator helper not reported: $out"; }
  pass "check verifies the operator's own push credentials"
}

test_operator_store_helper_with_github_entry_is_accepted() {
  local out rc
  mv "$TMP_ROOT/ophome/.gitconfig" "$TMP_ROOT/ophome/.gitconfig.off"
  printf '[credential]\n\thelper = store\n' > "$TMP_ROOT/ophome/.gitconfig"
  mv "$TMP_ROOT/ophome/.git-credentials" "$TMP_ROOT/ophome/.git-credentials.off"
  printf 'https://user:token@github.com\n' > "$TMP_ROOT/ophome/.git-credentials"
  out=$(run_setup check); rc=$?
  mv "$TMP_ROOT/ophome/.git-credentials.off" "$TMP_ROOT/ophome/.git-credentials"
  mv "$TMP_ROOT/ophome/.gitconfig.off" "$TMP_ROOT/ophome/.gitconfig"
  ! grep -q 'MISSING operator push credentials' <<<"$out" || { fail "store helper with a github.com entry rejected (rc=$rc): $out"; }
  grep -q 'ok      operator push credentials: git credential' <<<"$out" || { fail "store helper not confirmed: $out"; }
  pass "a store helper holding a github.com entry is accepted"
}

test_operator_cache_only_helper_is_rejected() {
  local out rc
  printf '[credential]\n\thelper = cache\n' > "$TMP_ROOT/ophome/.gitconfig.cache"
  mv "$TMP_ROOT/ophome/.gitconfig" "$TMP_ROOT/ophome/.gitconfig.off"
  mv "$TMP_ROOT/ophome/.gitconfig.cache" "$TMP_ROOT/ophome/.gitconfig"
  out=$(run_setup check); rc=$?
  mv "$TMP_ROOT/ophome/.gitconfig.off" "$TMP_ROOT/ophome/.gitconfig"
  [[ $rc -eq 1 ]] || { fail "cache-only helper must fail the check (rc=$rc): $out"; }
  grep -q 'MISSING operator push credentials: no git credential for github.com' <<<"$out" || { fail "cache-only helper not reported: $out"; }
  pass "a helper that cannot serve github.com is rejected"
}

test_projects_step_checks_and_applies_clone_access() {
  local home="$TMP_ROOT/projhome" out rc
  mkdir -p "$home/projects/p1" "$home/data"
  git -C "$home/projects/p1" init -q
  out=$(FM_HOME="$home" run_setup check); rc=$?
  [[ $rc -eq 1 ]] || { fail "check must fail while a project clone grants the pool account nothing (rc=$rc): $out"; }
  grep -q "MISSING project clone $home/projects/p1 not writable by $ME" <<<"$out" || { fail "unwritable clone not reported: $out"; }
  out=$(FM_HOME="$home" run_setup apply); rc=$?
  grep -q "fixed   ACL (access + default) for $ME on $home/projects/p1" <<<"$out" || { fail "apply did not grant the clone: $out"; }
  out=$(FM_HOME="$home" run_setup check)
  grep -q "ok      project clone $home/projects/p1 writable by $ME" <<<"$out" || { fail "granted clone not confirmed: $out"; }
  printf -- '- mate1 - Mate (home: %s/matehome; scope: tests; projects: none; added 2026-11-25)\n' "$TMP_ROOT" > "$home/data/secondmates.md"
  mkdir -p "$TMP_ROOT/matehome"
  out=$(FM_HOME="$home" run_setup check)
  grep -q "secondmate home $TMP_ROOT/matehome" <<<"$out" || { fail "local secondmate home not examined: $out"; }
  pass "the projects step reports an ungranted clone, applies the ACL, and examines local secondmate homes"
}

fm_test_run test_check_is_read_only_and_reports_missing test_apply_is_idempotent_and_check_then_passes test_root_steps_print_commands test_nm_config_never_edited test_unreachable_ancestor_is_not_reported_ok test_operator_push_credentials_are_checked test_operator_cache_only_helper_is_rejected test_operator_store_helper_with_github_entry_is_accepted test_projects_step_checks_and_applies_clone_access
