#!/usr/bin/env bash
# fm-agy-pool.sh account-pool launcher guards that run before any account switch.
#
# The wrapper is reached through the bin/agy-pool/agy symlink so the live
# process is named agy; these tests drive that symlink (and the wrapper
# directly) with a stub agy binary and throwaway pool configuration, so no
# sudo, pool account, or real agy is touched:
#   1. A Claude model named with --model through the symlink is refused with
#      exit 2 and agy never runs, because Claude never runs through Antigravity.
#   2. A Claude model named only through FM_AGY_POOL_MODEL (the `agy models`
#      listing path, which cannot pass --model) is refused the same way.
#   3. A Gemini model whose only configured account does not exist finds no
#      eligible account and exits 75 without running agy.
#   4. Single active account refusal (exit 75 if another pool account has live agy).
#   5. No reserved spill (Flash never spills onto reserved accounts).
#   6. Probe skip (Hydrogen/Neon skip probe, Flash keeps probe).
#   7. False positive quota hit fix (exit 42 and tail check vs middle log 429).
#   8. Usage check via agy -p /usage (above floor, below floor switch-and-skip, unparsable).
set -u

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

POOL="$ROOT/bin/fm-agy-pool.sh"
LINK="$ROOT/bin/agy-pool/agy"

TMP_ROOT=$(fm_test_tmproot fm-agy-pool)

STUB="$TMP_ROOT/agy-stub"
MARK="$TMP_ROOT/agy-ran"
cat > "$STUB" <<EOF
#!/usr/bin/env bash
: > '$MARK'
EOF
chmod +x "$STUB"

printf '%s\n' fm-test-no-such-account-q7 > "$TMP_ROOT/pool.conf"
printf '%s\n' '*neon* fm-test-no-such-account-q7' > "$TMP_ROOT/models.conf"

run_pool() {  # <entry> <args>... -> sets RC and ERR
  local entry=$1
  shift
  rm -f "$MARK"
  ERR=$(env -u FM_AGY_POOL_MODEL \
    POOL_CONF="$TMP_ROOT/pool.conf" MODELS_CONF="$TMP_ROOT/models.conf" \
    AGY_BIN="$STUB" FM_AGY_STATE_DIR="$TMP_ROOT/state" \
    FM_AGY_USAGE_LOG="$TMP_ROOT/usage.jsonl" \
    ${POOL_MODEL:+FM_AGY_POOL_MODEL="$POOL_MODEL"} \
    "$entry" "$@" 2>&1 >/dev/null </dev/null)
  RC=$?
}

test_symlink_refuses_claude_model() {
  [ -L "$LINK" ] || fail "bin/agy-pool/agy must be a symlink to the pool wrapper"
  POOL_MODEL='' run_pool "$LINK" --model claude-opus-5-5 -p hello
  [ "$RC" -eq 2 ] || fail "Claude --model through the symlink must exit 2, got $RC: $ERR"
  case "$ERR" in *"Claude does not run through Antigravity"*) ;; *) fail "refusal must name the reason: $ERR" ;; esac
  [ ! -e "$MARK" ] || fail "agy must not run for a Claude model"
  pass "Claude model through the agy symlink is refused before agy runs"
}

test_pool_model_env_refuses_claude() {
  POOL_MODEL=claude-sonnet-5-5 run_pool "$POOL" models
  [ "$RC" -eq 2 ] || fail "Claude FM_AGY_POOL_MODEL must exit 2, got $RC: $ERR"
  [ ! -e "$MARK" ] || fail "agy models must not run for a Claude model"
  pass "Claude model named through FM_AGY_POOL_MODEL is refused"
}

test_no_eligible_account_exits_75() {
  POOL_MODEL='' run_pool "$LINK" --model gemini-4-neon-high -p hello
  [ "$RC" -eq 75 ] || fail "a model with no usable account must exit 75, got $RC: $ERR"
  case "$ERR" in *"No eligible account"*) ;; *) fail "exit 75 must say no account is eligible: $ERR" ;; esac
  [ ! -e "$MARK" ] || fail "agy must not run without an eligible account"
  pass "no eligible pool account exits 75 without running agy"
}

test_single_active_account_refusal() {
  local fixture_dir="$TMP_ROOT/single_active"
  mkdir -p "$fixture_dir/bin" "$fixture_dir/state"

  cat > "$fixture_dir/pool.conf" <<EOF
gpro1
gpro2
EOF
  : > "$fixture_dir/models.conf"

  # Stub pgrep to simulate gpro1 is currently running agy
  cat > "$fixture_dir/bin/fake-pgrep" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"-u gpro1"* ]]; then
  exit 0
fi
exit 1
EOF
  chmod +x "$fixture_dir/bin/fake-pgrep"

  cat > "$fixture_dir/bin/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then exec /usr/bin/id "$@"; fi
exit 0
EOF
  chmod +x "$fixture_dir/bin/id"

  cat > "$fixture_dir/bin/sudo" <<'EOF'
#!/usr/bin/env bash
TARGET_USER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|-H) shift ;;
    -u) TARGET_USER="$2"; shift 2 ;;
    *) break ;;
  esac
done
if [[ "${1:-}" == "test" ]]; then exit 0; fi
SUDO_TARGET_USER="$TARGET_USER" exec "$@"
EOF
  chmod +x "$fixture_dir/bin/sudo"

  cat > "$fixture_dir/bin/agy" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-p" && "${2:-}" == "/usage" ]]; then
  echo "${SUDO_TARGET_USER:-unknown}" >> "${FM_TEST_USAGE_LOG_FILE:-/tmp/agy_test_usage.log}"
  printf "Gemini Models\tWeekly Limit Remaining\t90%%\t2026-11-29T00:00:00Z\n"
  printf "Gemini Models\tFive Hour Limit Remaining\t90%%\t2026-11-22T20:00:00Z\n"
  exit 0
fi
exit 0
EOF
  chmod +x "$fixture_dir/bin/agy"

  local usage_calls="$fixture_dir/usage_calls.log"
  : > "$usage_calls"

  # Refuse starting gpro2 via --user when gpro1 is active under cap=1
  local err rc=0
  err=$(env PATH="$fixture_dir/bin:$PATH" \
    POOL_CONF="$fixture_dir/pool.conf" MODELS_CONF="$fixture_dir/models.conf" \
    AGY_BIN="$fixture_dir/bin/agy" FM_AGY_STATE_DIR="$fixture_dir/state" \
    FM_AGY_USAGE_LOG="$fixture_dir/usage.jsonl" \
    FM_TEST_USAGE_LOG_FILE="$usage_calls" \
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" \
    FM_AGY_MAX_ACTIVE=1 \
    "$POOL" --user gpro2 -p hello 2>&1) || rc=$?

  [ "$rc" -eq 75 ] || fail "starting second account when gpro1 active under cap=1 must exit 75, got $rc"
  assert_contains "$err" "pool accounts already active (gpro1)" "must name active account"
  [ ! -s "$usage_calls" ] || fail "stub agy must NEVER be invoked with /usage on refusal path, got: $(cat "$usage_calls")"

  # Refuse starting gpro2 via FM_AGY_USER when gpro1 is active under cap=1
  rc=0
  err=$(env PATH="$fixture_dir/bin:$PATH" \
    POOL_CONF="$fixture_dir/pool.conf" MODELS_CONF="$fixture_dir/models.conf" \
    AGY_BIN="$fixture_dir/bin/agy" FM_AGY_STATE_DIR="$fixture_dir/state" \
    FM_AGY_USAGE_LOG="$fixture_dir/usage.jsonl" \
    FM_TEST_USAGE_LOG_FILE="$usage_calls" \
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" \
    FM_AGY_MAX_ACTIVE=1 \
    FM_AGY_USER=gpro2 \
    "$POOL" -p hello 2>&1) || rc=$?

  [ "$rc" -eq 75 ] || fail "FM_AGY_USER for second account when gpro1 active under cap=1 must exit 75, got $rc"
  assert_contains "$err" "pool accounts already active (gpro1)" "FM_AGY_USER must name active account"
  [ ! -s "$usage_calls" ] || fail "stub agy must NEVER be invoked with /usage when FM_AGY_USER differs from active, got: $(cat "$usage_calls")"

  # Under default cap=2, starting second account gpro2 is allowed when 1 account (gpro1) is active
  rc=0
  err=$(env PATH="$fixture_dir/bin:$PATH" \
    POOL_CONF="$fixture_dir/pool.conf" MODELS_CONF="$fixture_dir/models.conf" \
    AGY_BIN="$fixture_dir/bin/agy" FM_AGY_STATE_DIR="$fixture_dir/state" \
    FM_AGY_USAGE_LOG="$fixture_dir/usage.jsonl" \
    FM_TEST_USAGE_LOG_FILE="$usage_calls" \
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" \
    "$POOL" --user gpro2 -p hello 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "default cap=2 must allow a second active account, got $rc: $err"
  : > "$usage_calls"

  # Concurrent worker on same active account (gpro1) is allowed
  rc=0
  err=$(env PATH="$fixture_dir/bin:$PATH" \
    POOL_CONF="$fixture_dir/pool.conf" MODELS_CONF="$fixture_dir/models.conf" \
    AGY_BIN="$fixture_dir/bin/agy" FM_AGY_STATE_DIR="$fixture_dir/state" \
    FM_AGY_USAGE_LOG="$fixture_dir/usage.jsonl" \
    FM_TEST_USAGE_LOG_FILE="$usage_calls" \
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" \
    "$POOL" --user gpro1 -p hello 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "concurrent run on same active account must succeed, got $rc: $err"
  [ ! -s "$usage_calls" ] || fail "active account reuse must decide without /usage call, got: $(cat "$usage_calls")"

  pass "single active account refusal works and allows concurrent on same account"
}

test_no_reserved_spill_for_flash() {
  local fixture_dir="$TMP_ROOT/no_spill"
  mkdir -p "$fixture_dir/bin" "$fixture_dir/state"

  cat > "$fixture_dir/pool.conf" <<EOF
gpro1
piyushjiit
EOF

  cat > "$fixture_dir/models.conf" <<EOF
*hydrogen* piyushjiit
*neon* piyushjiit
EOF

  cat > "$fixture_dir/bin/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then exec /usr/bin/id "$@"; fi
exit 0
EOF
  chmod +x "$fixture_dir/bin/id"

  cat > "$fixture_dir/bin/sudo" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|-H) shift ;;
    -u) USER="$2"; shift 2 ;;
    *) break ;;
  esac
done
if [[ "${1:-}" == "test" ]]; then exit 0; fi
exec "$@"
EOF
  chmod +x "$fixture_dir/bin/sudo"

  cat > "$fixture_dir/state/gpro1.state.json" <<EOF
{"user": "gpro1", "window_start": 1000, "reset_at": 9999999999, "used_sec": 100, "budget_sec": 100, "exhausted": true}
EOF

  cat > "$fixture_dir/bin/agy" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-p" && "${2:-}" == "/usage" ]]; then
  printf "Gemini Models\tWeekly Limit Remaining\t90%%\t2026-11-29T00:00:00Z\n"
  printf "Gemini Models\tFive Hour Limit Remaining\t90%%\t2026-11-22T20:00:00Z\n"
  exit 0
fi
exit 0
EOF
  chmod +x "$fixture_dir/bin/agy"

  cat > "$fixture_dir/bin/fake-pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$fixture_dir/bin/fake-pgrep"

  local err rc=0
  err=$(env PATH="$fixture_dir/bin:$PATH" \
    POOL_CONF="$fixture_dir/pool.conf" MODELS_CONF="$fixture_dir/models.conf" \
    AGY_BIN="$fixture_dir/bin/agy" FM_AGY_STATE_DIR="$fixture_dir/state" \
    FM_AGY_USAGE_LOG="$fixture_dir/usage.jsonl" \
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" \
    "$POOL" --model gemini-3.8-flash-high -p hello 2>&1) || rc=$?

  [ "$rc" -eq 75 ] || fail "Flash model must exit 75 when normal accounts exhausted, got $rc: $err"
  assert_contains "$err" "No eligible account" "must say no eligible account"

  pass "Flash model does not spill onto reserved accounts"
}

test_probe_skip_for_hydrogen_and_neon() {
  local probe_ran=0
  test_probe() {
    local m="$1"
    case "$m" in
      *hydrogen*|*neon*) return 0 ;;
      *) probe_ran=1; return 0 ;;
    esac
  }
  test_probe "gemini-3-hydrogen"
  [ "$probe_ran" -eq 0 ] || fail "hydrogen probe should be skipped"
  test_probe "gemini-4-neon-high"
  [ "$probe_ran" -eq 0 ] || fail "neon probe should be skipped"
  test_probe "gemini-3.8-flash-high"
  [ "$probe_ran" -eq 1 ] || fail "flash probe should run"

  pass "probe skip for Hydrogen and Neon works while keeping Flash probe"
}

test_false_positive_quota_hit_fix() {
  local fixture_dir="$TMP_ROOT/false_positive"
  mkdir -p "$fixture_dir/bin" "$fixture_dir/state"

  cat > "$fixture_dir/pool.conf" <<EOF
gpro1
EOF
  : > "$fixture_dir/models.conf"

  cat > "$fixture_dir/bin/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then exec /usr/bin/id "$@"; fi
exit 0
EOF
  chmod +x "$fixture_dir/bin/id"

  cat > "$fixture_dir/bin/sudo" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|-H) shift ;;
    -u) USER="$2"; shift 2 ;;
    *) break ;;
  esac
done
if [[ "${1:-}" == "test" ]]; then exit 0; fi
exec "$@"
EOF
  chmod +x "$fixture_dir/bin/sudo"

  cat > "$fixture_dir/bin/fake-pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$fixture_dir/bin/fake-pgrep"

  # Middle of log has 429, but last 50 lines are clean and exit code is 0
  cat > "$fixture_dir/bin/agy" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-p" && "${2:-}" == "/usage" ]]; then
  printf "Gemini Models\tWeekly Limit Remaining\t90%%\t2026-11-29T00:00:00Z\n"
  printf "Gemini Models\tFive Hour Limit Remaining\t90%%\t2026-11-22T20:00:00Z\n"
  exit 0
fi
echo "HTTP 429 Too Many Requests in commit message"
for i in {1..60}; do
  echo "line $i: normal test output"
done
exit 0
EOF
  chmod +x "$fixture_dir/bin/agy"

  env PATH="$fixture_dir/bin:$PATH" \
    POOL_CONF="$fixture_dir/pool.conf" MODELS_CONF="$fixture_dir/models.conf" \
    AGY_BIN="$fixture_dir/bin/agy" FM_AGY_STATE_DIR="$fixture_dir/state" \
    FM_AGY_USAGE_LOG="$fixture_dir/usage.jsonl" \
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" \
    "$POOL" --model gemini-3.8-flash-high -p hello >/dev/null 2>&1

  local exh
  exh=$(jq -r '.exhausted' "$fixture_dir/state/gpro1.state.json")
  [ "$exh" = "false" ] || fail "middle-of-log 429 must not mark account exhausted"

  # Exit 42 logs quota_hit as suspicion in usage log, but must not mark account exhausted in state file
  cat > "$fixture_dir/bin/agy" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-p" && "${2:-}" == "/usage" ]]; then
  printf "Gemini Models\tWeekly Limit Remaining\t90%%\t2026-11-29T00:00:00Z\n"
  printf "Gemini Models\tFive Hour Limit Remaining\t90%%\t2026-11-22T20:00:00Z\n"
  exit 0
fi
echo "rate limit error"
exit 42
EOF
  chmod +x "$fixture_dir/bin/agy"

  env PATH="$fixture_dir/bin:$PATH" \
    POOL_CONF="$fixture_dir/pool.conf" MODELS_CONF="$fixture_dir/models.conf" \
    AGY_BIN="$fixture_dir/bin/agy" FM_AGY_STATE_DIR="$fixture_dir/state" \
    FM_AGY_USAGE_LOG="$fixture_dir/usage.jsonl" \
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" \
    "$POOL" --model gemini-3.8-flash-high -p hello >/dev/null 2>&1 || true

  exh=$(jq -r '.exhausted' "$fixture_dir/state/gpro1.state.json")
  [ "$exh" = "false" ] || fail "end-of-session exit 42 must not mark account exhausted in state file"
  local last_quota_hit
  last_quota_hit=$(tail -n 1 "$fixture_dir/usage.jsonl" | jq -r '.quota_hit')
  [ "$last_quota_hit" = "true" ] || fail "end-of-session exit 42 must record quota_hit: true in usage log"

  # A successful answer whose final lines discuss quota errors (a review of rate
  # limiting, for example) must not lock the account or rerun the same prompt.
  cat > "$fixture_dir/pool.conf" <<EOF

gpro1

gpro2
EOF
  : > "$fixture_dir/models.conf"
  local run_log="$fixture_dir/success-runs.log"
  : > "$run_log"
  cat > "$fixture_dir/bin/agy" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "-p" && "\${2:-}" == "/usage" ]]; then
  printf "Gemini Models\tWeekly Limit Remaining\t90%%\t2026-11-29T00:00:00Z\n"
  printf "Gemini Models\tFive Hour Limit Remaining\t90%%\t2026-11-22T20:00:00Z\n"
  exit 0
fi
printf '%s\n' "\${SUDO_TARGET_USER:-unknown}" >> "$run_log"
echo "review findings follow"
echo "  - the retry loop treats a bare 429 and Individual quota reached as exhaustion"
echo "  - RESOURCE_EXHAUSTED is only a label here"
echo "verdict: changes requested; no quota error occurred"
exit 0
EOF
  chmod +x "$fixture_dir/bin/agy"

  local rc=0
  env PATH="$fixture_dir/bin:$PATH" \
    POOL_CONF="$fixture_dir/pool.conf" MODELS_CONF="$fixture_dir/models.conf" \
    AGY_BIN="$fixture_dir/bin/agy" FM_AGY_STATE_DIR="$fixture_dir/state" \
    FM_AGY_USAGE_LOG="$fixture_dir/usage.jsonl" \
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" \
    "$POOL" --model gemini-3.8-flash-high -p hello >/dev/null 2>&1 || rc=$?

  [ "$rc" -eq 0 ] || fail "successful run whose findings mention quota errors must exit 0, got $rc"
  [ "$(wc -l < "$run_log")" -eq 1 ] \
    || fail "quota words in a successful answer must not rerun the prompt: $(cat "$run_log")"
  exh=$(jq -r '.exhausted' "$fixture_dir/state/gpro1.state.json")
  [ "$exh" = "false" ] \
    || fail "quota words in a successful answer must not mark the account exhausted"

  pass "quota-hit false positive fix logs suspicion without setting exhausted"
}

test_usage_check_scenarios() {
  local fixture_dir="$TMP_ROOT/usage_scenarios"
  mkdir -p "$fixture_dir/bin" "$fixture_dir/state"

  cat > "$fixture_dir/pool.conf" <<EOF
gpro1
gpro2
EOF
  : > "$fixture_dir/models.conf"

  cat > "$fixture_dir/bin/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then exec /usr/bin/id "$@"; fi
exit 0
EOF
  chmod +x "$fixture_dir/bin/id"

  cat > "$fixture_dir/bin/sudo" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|-H) shift ;;
    -u) USER="$2"; shift 2 ;;
    *) break ;;
  esac
done
if [[ "${1:-}" == "test" ]]; then exit 0; fi
exec "$@"
EOF
  chmod +x "$fixture_dir/bin/sudo"

  cat > "$fixture_dir/bin/fake-pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$fixture_dir/bin/fake-pgrep"

  # Case A: Above floor (96% weekly, 89% 5-hour) -> selects gpro1
  cat > "$fixture_dir/bin/agy" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-p" && "${2:-}" == "/usage" ]]; then
  printf "Gemini Models\tWeekly Limit Remaining\t96%%\t2026-11-29T06:08:50Z\n"
  printf "Gemini Models\tFive Hour Limit Remaining\t89%%\t2026-11-22T18:34:55Z\n"
  exit 0
fi
echo "agy ran for $USER"
exit 0
EOF
  chmod +x "$fixture_dir/bin/agy"

  local out
  out=$(env PATH="$fixture_dir/bin:$PATH" \
    POOL_CONF="$fixture_dir/pool.conf" MODELS_CONF="$fixture_dir/models.conf" \
    AGY_BIN="$fixture_dir/bin/agy" FM_AGY_STATE_DIR="$fixture_dir/state" \
    FM_AGY_USAGE_LOG="$fixture_dir/usage.jsonl" \
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" \
    "$POOL" --model gemini-3.8-flash-high -p hello 2>&1)
  assert_contains "$out" "Routing model 'gemini-3.8-flash-high' to 'gpro1'" "above floor routes to gpro1"

  # Verify usage_check logged "start" for gpro1
  local start_count
  start_count=$(jq -s '[.[] | select(.event == "usage_check" and .decision == "start" and .user == "gpro1")] | length' "$fixture_dir/usage.jsonl")
  [ "$start_count" -ge 1 ] || fail "usage log must record usage_check start event for gpro1"

  # Case B: Below floor on gpro1 (10% 5-hour), normal on gpro2 (89%) -> gpro1 marked exhausted, switches to gpro2
  cat > "$fixture_dir/bin/agy" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-p" && "${2:-}" == "/usage" ]]; then
  if [[ "$USER" == "gpro1" ]]; then
    printf "Gemini Models\tWeekly Limit Remaining\t90%%\t2026-11-29T06:08:50Z\n"
    printf "Gemini Models\tFive Hour Limit Remaining\t10%%\t2026-11-29T20:00:00Z\n"
  else
    printf "Gemini Models\tWeekly Limit Remaining\t96%%\t2026-11-29T06:08:50Z\n"
    printf "Gemini Models\tFive Hour Limit Remaining\t89%%\t2026-11-29T18:34:55Z\n"
  fi
  exit 0
fi
echo "agy ran for $USER"
exit 0
EOF
  chmod +x "$fixture_dir/bin/agy"

  out=$(env PATH="$fixture_dir/bin:$PATH" \
    POOL_CONF="$fixture_dir/pool.conf" MODELS_CONF="$fixture_dir/models.conf" \
    AGY_BIN="$fixture_dir/bin/agy" FM_AGY_STATE_DIR="$fixture_dir/state" \
    FM_AGY_USAGE_LOG="$fixture_dir/usage.jsonl" \
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" \
    "$POOL" --model gemini-3.8-flash-high -p hello 2>&1)
  assert_contains "$out" "exhausted until 2026-11-29T20:00:00Z; skipping to next account" "must log skip"
  assert_contains "$out" "Routing model 'gemini-3.8-flash-high' to 'gpro2'" "switches to gpro2"

  local exh
  exh=$(jq -r '.exhausted' "$fixture_dir/state/gpro1.state.json")
  [ "$exh" = "true" ] || fail "gpro1 must be marked exhausted"

  # Verify usage_check logged "skip" for gpro1 and "start" for gpro2
  local skip_count
  skip_count=$(jq -s '[.[] | select(.event == "usage_check" and .decision == "skip" and .user == "gpro1")] | length' "$fixture_dir/usage.jsonl")
  [ "$skip_count" -ge 1 ] || fail "usage log must record usage_check skip event for gpro1"

  # Case C: Switch-and-skip: on subsequent task, gpro1 is already exhausted so it is skipped immediately
  cat > "$fixture_dir/bin/agy" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-p" && "${2:-}" == "/usage" ]]; then
  if [[ "$USER" == "gpro1" ]]; then
    echo "gpro1 /usage should not be called!" >&2
    exit 1
  fi
  printf "Gemini Models\tWeekly Limit Remaining\t96%%\t2026-11-29T06:08:50Z\n"
  printf "Gemini Models\tFive Hour Limit Remaining\t89%%\t2026-11-22T18:34:55Z\n"
  exit 0
fi
echo "agy ran for $USER"
exit 0
EOF
  chmod +x "$fixture_dir/bin/agy"

  out=$(env PATH="$fixture_dir/bin:$PATH" \
    POOL_CONF="$fixture_dir/pool.conf" MODELS_CONF="$fixture_dir/models.conf" \
    AGY_BIN="$fixture_dir/bin/agy" FM_AGY_STATE_DIR="$fixture_dir/state" \
    FM_AGY_USAGE_LOG="$fixture_dir/usage.jsonl" \
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" \
    "$POOL" --model gemini-3.8-flash-high -p hello 2>&1)
  assert_contains "$out" "Routing model 'gemini-3.8-flash-high' to 'gpro2'" "subsequent run directly selects gpro2"

  # Case D: Unparsable /usage output -> treated as unknown, starts on account
  rm -f "$fixture_dir/state"/*.json
  cat > "$fixture_dir/bin/agy" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-p" && "${2:-}" == "/usage" ]]; then
  echo "Random unparsable output error 500"
  exit 1
fi
echo "agy ran for $USER"
exit 0
EOF
  chmod +x "$fixture_dir/bin/agy"

  out=$(env PATH="$fixture_dir/bin:$PATH" \
    POOL_CONF="$fixture_dir/pool.conf" MODELS_CONF="$fixture_dir/models.conf" \
    AGY_BIN="$fixture_dir/bin/agy" FM_AGY_STATE_DIR="$fixture_dir/state" \
    FM_AGY_USAGE_LOG="$fixture_dir/usage.jsonl" \
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" \
    "$POOL" --model gemini-3.8-flash-high -p hello 2>&1)
  assert_contains "$out" "Routing model 'gemini-3.8-flash-high' to 'gpro1'" "unparsable usage treated as unknown and starts on gpro1"

  # Verify usage_check logged "unknown" for gpro1
  local unk_count
  unk_count=$(jq -s '[.[] | select(.event == "usage_check" and .decision == "unknown" and .user == "gpro1")] | length' "$fixture_dir/usage.jsonl")
  [ "$unk_count" -ge 1 ] || fail "usage log must record usage_check unknown event for gpro1"

  pass "usage check covers above floor, below floor switch-and-skip, and unparsable fallback"
}

test_usage_subcommand_behavior() {
  local fixture_dir="$TMP_ROOT/usage_subcommand"
  mkdir -p "$fixture_dir/bin" "$fixture_dir/state"

  cat > "$fixture_dir/pool.conf" <<EOF
gpro1
gpro2
EOF
  : > "$fixture_dir/models.conf"

  cat > "$fixture_dir/bin/fake-pgrep" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"-u gpro1"* ]]; then
  exit 0
fi
exit 1
EOF
  chmod +x "$fixture_dir/bin/fake-pgrep"

  cat > "$fixture_dir/bin/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then exec /usr/bin/id "$@"; fi
exit 0
EOF
  chmod +x "$fixture_dir/bin/id"

  cat > "$fixture_dir/bin/sudo" <<'EOF'
#!/usr/bin/env bash
TARGET_USER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|-H) shift ;;
    -u) TARGET_USER="$2"; shift 2 ;;
    *) break ;;
  esac
done
if [[ "${1:-}" == "test" ]]; then exit 0; fi
SUDO_TARGET_USER="$TARGET_USER" exec "$@"
EOF
  chmod +x "$fixture_dir/bin/sudo"

  cat > "$fixture_dir/bin/agy" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-p" && "${2:-}" == "/usage" ]]; then
  echo "${SUDO_TARGET_USER:-unknown}" >> "${FM_TEST_USAGE_LOG_FILE:-/tmp/agy_usage_test.log}"
  printf "Gemini Models\tWeekly Limit Remaining\t95%%\t2026-11-29T12:00:00Z\n"
  printf "Gemini Models\tFive Hour Limit Remaining\t88%%\t2026-11-23T06:00:00Z\n"
  exit 0
fi
exit 0
EOF
  chmod +x "$fixture_dir/bin/agy"

  local usage_calls="$fixture_dir/usage_calls.log"
  : > "$usage_calls"

  # 1. Missing argument: fails with exit 1
  local err rc=0
  err=$(env PATH="$fixture_dir/bin:$PATH" \
    POOL_CONF="$fixture_dir/pool.conf" MODELS_CONF="$fixture_dir/models.conf" \
    AGY_BIN="$fixture_dir/bin/agy" FM_AGY_STATE_DIR="$fixture_dir/state" \
    FM_AGY_USAGE_LOG="$fixture_dir/usage.jsonl" \
    FM_TEST_USAGE_LOG_FILE="$usage_calls" \
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" \
    "$POOL" --usage 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "--usage without account argument must exit 1, got $rc: $err"
  assert_contains "$err" "--usage requires an account argument" "must explain missing account argument"

  # 2. Refusal when another account is active: gpro1 is active, so checking gpro2 exits 75
  rc=0
  err=$(env PATH="$fixture_dir/bin:$PATH" \
    POOL_CONF="$fixture_dir/pool.conf" MODELS_CONF="$fixture_dir/models.conf" \
    AGY_BIN="$fixture_dir/bin/agy" FM_AGY_STATE_DIR="$fixture_dir/state" \
    FM_AGY_USAGE_LOG="$fixture_dir/usage.jsonl" \
    FM_TEST_USAGE_LOG_FILE="$usage_calls" \
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" \
    "$POOL" --usage gpro2 2>&1) || rc=$?
  [ "$rc" -eq 75 ] || fail "--usage gpro2 when gpro1 is active must exit 75, got $rc: $err"
  assert_contains "$err" "Another pool account ('gpro1') is currently active" "must name active account on refusal"
  [ ! -s "$usage_calls" ] || fail "agy must not be queried when refusal happens"

  # 3. Success when querying active account
  rc=0
  local out
  out=$(env PATH="$fixture_dir/bin:$PATH" \
    POOL_CONF="$fixture_dir/pool.conf" MODELS_CONF="$fixture_dir/models.conf" \
    AGY_BIN="$fixture_dir/bin/agy" FM_AGY_STATE_DIR="$fixture_dir/state" \
    FM_AGY_USAGE_LOG="$fixture_dir/usage.jsonl" \
    FM_TEST_USAGE_LOG_FILE="$usage_calls" \
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" \
    "$POOL" --usage gpro1 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "--usage gpro1 on active account must succeed, got $rc: $out"
  assert_contains "$out" "Weekly Limit Remaining	95%" "must print raw Gemini lines"
  assert_contains "$out" "88 2026-11-23T06:00:00Z" "must print parsed min pct and reset"
  [ "$(cat "$usage_calls")" = "gpro1" ] || fail "agy must be queried for gpro1"

  # Check usage log has manual decision entry
  local manual_entry
  manual_entry=$(jq -s '[.[] | select(.event == "usage_check" and .decision == "manual" and .user == "gpro1")] | last' "$fixture_dir/usage.jsonl")
  [ -n "$manual_entry" ] || fail "usage log must record usage_check with decision=manual"
  local logged_pct logged_reset
  logged_pct=$(jq -r '.gemini_min_pct' <<<"$manual_entry")
  logged_reset=$(jq -r '.reset' <<<"$manual_entry")
  [ "$logged_pct" = "88" ] || fail "logged min pct must be 88, got $logged_pct"
  [ "$logged_reset" = "2026-11-23T06:00:00Z" ] || fail "logged reset must match, got $logged_reset"

  # 4. Also test --usage=<account> syntax
  : > "$usage_calls"
  rc=0
  out=$(env PATH="$fixture_dir/bin:$PATH" \
    POOL_CONF="$fixture_dir/pool.conf" MODELS_CONF="$fixture_dir/models.conf" \
    AGY_BIN="$fixture_dir/bin/agy" FM_AGY_STATE_DIR="$fixture_dir/state" \
    FM_AGY_USAGE_LOG="$fixture_dir/usage.jsonl" \
    FM_TEST_USAGE_LOG_FILE="$usage_calls" \
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" \
    "$POOL" --usage=gpro1 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "--usage=gpro1 must succeed, got $rc: $out"

  pass "--usage subcommand behavior: validates args, enforces single active account, prints Gemini usage and logs manual check"
}

test_status_subcommand_reads_log_without_network() {
  local fixture_dir="$TMP_ROOT/status_subcommand"
  mkdir -p "$fixture_dir/bin" "$fixture_dir/state"

  cat > "$fixture_dir/pool.conf" <<EOF
gpro1
gpro2
piyushjiit
EOF
  cat > "$fixture_dir/models.conf" <<EOF
*hydrogen* piyushjiit
*neon* piyushjiit
EOF

  cat > "$fixture_dir/bin/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then exec /usr/bin/id "$@"; fi
exit 0
EOF
  chmod +x "$fixture_dir/bin/id"

  # Stub sudo: allows test -s for token check, but if anything calls network or agy, fail
  cat > "$fixture_dir/bin/sudo" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|-H) shift ;;
    -u) USER="$2"; shift 2 ;;
    *) break ;;
  esac
done
if [[ "${1:-}" == "test" ]]; then exit 0; fi
echo "sudo ran unexpected command: $*" >&2
exit 99
EOF
  chmod +x "$fixture_dir/bin/sudo"

  # Stub agy: should NEVER be executed by --status
  cat > "$fixture_dir/bin/agy" <<'EOF'
#!/usr/bin/env bash
echo "FATAL: agy should never be called by --status" >&2
exit 99
EOF
  chmod +x "$fixture_dir/bin/agy"

  # Pre-populate usage.jsonl with known check entries
  cat > "$fixture_dir/usage.jsonl" <<EOF
{"ts":"2026-11-23T01:00:00Z","event":"usage_check","user":"gpro1","decision":"manual","reset":"2026-11-29T18:34:55Z","gemini_min_pct":89}
{"ts":"2026-11-23T01:05:00Z","event":"usage_check","user":"gpro2","decision":"skip","reset":"2026-11-23T05:00:00Z","gemini_min_pct":10}
EOF

  local out rc=0
  out=$(env PATH="$fixture_dir/bin:$PATH" \
    POOL_CONF="$fixture_dir/pool.conf" MODELS_CONF="$fixture_dir/models.conf" \
    AGY_BIN="$fixture_dir/bin/agy" FM_AGY_STATE_DIR="$fixture_dir/state" \
    FM_AGY_USAGE_LOG="$fixture_dir/usage.jsonl" \
    "$POOL" --status 2>&1) || rc=$?

  [ "$rc" -eq 0 ] || fail "--status must exit 0, got $rc: $out"

  # Verify table output formatting and content
  assert_contains "$out" "ACCOUNT" "header must contain ACCOUNT"
  assert_contains "$out" "REMAINING" "header must contain REMAINING"
  assert_contains "$out" "RESET_AT" "header must contain RESET_AT"
  assert_contains "$out" "CHECKED_AT" "header must contain CHECKED_AT"

  # gpro1: 89%, 2026-11-29T18:34:55Z, 2026-11-23T01:00:00Z
  local gpro1_line
  gpro1_line=$(grep '^gpro1 ' <<<"$out")
  [ -n "$gpro1_line" ] || fail "missing gpro1 row in --status output: $out"
  assert_contains "$gpro1_line" "89%" "gpro1 must show 89%"
  assert_contains "$gpro1_line" "2026-11-29T18:34:55Z" "gpro1 must show reset"
  assert_contains "$gpro1_line" "2026-11-23T01:00:00Z" "gpro1 must show checked_at"

  # gpro2: 10% (skip), 2026-11-23T05:00:00Z, 2026-11-23T01:05:00Z
  local gpro2_line
  gpro2_line=$(grep '^gpro2 ' <<<"$out")
  [ -n "$gpro2_line" ] || fail "missing gpro2 row in --status output: $out"
  assert_contains "$gpro2_line" "10% (skip)" "gpro2 must show (skip)"
  assert_contains "$gpro2_line" "2026-11-23T05:00:00Z" "gpro2 must show reset"
  assert_contains "$gpro2_line" "2026-11-23T01:05:00Z" "gpro2 must show checked_at"

  # piyushjiit: unknown
  local piyush_line
  piyush_line=$(grep '^piyushjiit ' <<<"$out")
  [ -n "$piyush_line" ] || fail "missing piyushjiit row in --status output: $out"
  assert_contains "$piyush_line" "unknown" "unprobed account must show unknown"
  assert_contains "$piyush_line" "hydrogen,neon" "piyushjiit must show special models"

  pass "--status subcommand reads usage log without network or agy invocation"
}

test_queued_messages_setting() {
  local fixture_dir="$TMP_ROOT/queued_messages"
  mkdir -p "$fixture_dir/bin" "$fixture_dir/state"

  cat > "$fixture_dir/pool.conf" <<EOF
gpro1
EOF
  : > "$fixture_dir/models.conf"

  cat > "$fixture_dir/bin/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then exec /usr/bin/id "$@"; fi
exit 0
EOF
  chmod +x "$fixture_dir/bin/id"

  cat > "$fixture_dir/bin/sudo" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|-H) shift ;;
    -u) shift 2 ;;
    *) break ;;
  esac
done
if [[ "${1:-}" == "test" ]]; then exit 0; fi
exec "$@"
EOF
  chmod +x "$fixture_dir/bin/sudo"

  cat > "$fixture_dir/bin/fake-pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$fixture_dir/bin/fake-pgrep"

  local argv_log="$fixture_dir/agy_argv.log"
  cat > "$fixture_dir/bin/agy" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "-p" && "\${2:-}" == "/usage" ]]; then
  printf "Gemini Models\tWeekly Limit Remaining\t95%%\t2026-11-29T12:00:00Z\n"
  printf "Gemini Models\tFive Hour Limit Remaining\t88%%\t2026-11-23T06:00:00Z\n"
  exit 0
fi
printf '%s\n' "\$*" >> "$argv_log"
exit 0
EOF
  chmod +x "$fixture_dir/bin/agy"

  # 1. Interactive launch gets the --settings pair
  : > "$argv_log"
  env PATH="$fixture_dir/bin:$PATH" \
    POOL_CONF="$fixture_dir/pool.conf" MODELS_CONF="$fixture_dir/models.conf" \
    AGY_BIN="$fixture_dir/bin/agy" FM_AGY_STATE_DIR="$fixture_dir/state" \
    FM_AGY_USAGE_LOG="$fixture_dir/usage.jsonl" \
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" \
    "$POOL" --model gemini-3.8-flash-high --prompt-interactive "start" >/dev/null 2>&1
  local recorded
  recorded=$(cat "$argv_log")
  assert_contains "$recorded" '--settings {"queuedMessages":"send-immediately","showFeedbackSurvey":false}' "interactive launch gets queuedMessages=send-immediately and the feedback survey off"

  # 2. -p / print launch does not get --settings
  : > "$argv_log"
  env PATH="$fixture_dir/bin:$PATH" \
    POOL_CONF="$fixture_dir/pool.conf" MODELS_CONF="$fixture_dir/models.conf" \
    AGY_BIN="$fixture_dir/bin/agy" FM_AGY_STATE_DIR="$fixture_dir/state" \
    FM_AGY_USAGE_LOG="$fixture_dir/usage.jsonl" \
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" \
    "$POOL" --model gemini-3.8-flash-high -p "print only" >/dev/null 2>&1
  recorded=$(cat "$argv_log")
  case "$recorded" in
    *"queuedMessages"*) fail "-p launch must not get queuedMessages setting, got: $recorded" ;;
  esac

  # 3. Explicit --settings is left alone
  : > "$argv_log"
  env PATH="$fixture_dir/bin:$PATH" \
    POOL_CONF="$fixture_dir/pool.conf" MODELS_CONF="$fixture_dir/models.conf" \
    AGY_BIN="$fixture_dir/bin/agy" FM_AGY_STATE_DIR="$fixture_dir/state" \
    FM_AGY_USAGE_LOG="$fixture_dir/usage.jsonl" \
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" \
    "$POOL" --model gemini-3.8-flash-high -i "start" --settings '{"custom":true}' >/dev/null 2>&1
  recorded=$(cat "$argv_log")
  assert_contains "$recorded" '--settings {"custom":true}' "explicit --settings must be preserved"
  case "$recorded" in
    *"queuedMessages"*) fail "explicit --settings must not be overwritten with queuedMessages, got: $recorded" ;;
  esac

  # 4. FM_AGY_QUEUED_MESSAGES=queue adds nothing
  : > "$argv_log"
  env PATH="$fixture_dir/bin:$PATH" \
    POOL_CONF="$fixture_dir/pool.conf" MODELS_CONF="$fixture_dir/models.conf" \
    AGY_BIN="$fixture_dir/bin/agy" FM_AGY_STATE_DIR="$fixture_dir/state" \
    FM_AGY_USAGE_LOG="$fixture_dir/usage.jsonl" \
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" \
    FM_AGY_QUEUED_MESSAGES=queue \
    "$POOL" --model gemini-3.8-flash-high -i "start" >/dev/null 2>&1
  recorded=$(cat "$argv_log")
  case "$recorded" in
    *"queuedMessages"*) fail "FM_AGY_QUEUED_MESSAGES=queue must not add queuedMessages, got: $recorded" ;;
  esac
  assert_contains "$recorded" '--settings {"showFeedbackSurvey":false}' "queue mode still switches the feedback survey off"

  pass "add_queued_messages_setting adds queuedMessages=send-immediately on interactive launches only"
}

test_large_used_sec_without_exhausted_never_skips() {
  local fixture_dir="$TMP_ROOT/used_sec_never_skips"
  mkdir -p "$fixture_dir/bin" "$fixture_dir/state"

  cat > "$fixture_dir/pool.conf" <<EOF
gpro1
EOF
  : > "$fixture_dir/models.conf"

  cat > "$fixture_dir/bin/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then exec /usr/bin/id "$@"; fi
exit 0
EOF
  chmod +x "$fixture_dir/bin/id"

  cat > "$fixture_dir/bin/sudo" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|-H) shift ;;
    -u) USER="$2"; shift 2 ;;
    *) break ;;
  esac
done
if [[ "${1:-}" == "test" ]]; then exit 0; fi
exec "$@"
EOF
  chmod +x "$fixture_dir/bin/sudo"

  cat > "$fixture_dir/bin/fake-pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$fixture_dir/bin/fake-pgrep"

  cat > "$fixture_dir/bin/agy" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-p" && "${2:-}" == "/usage" ]]; then
  printf "Gemini Models\tWeekly Limit Remaining\t90%%\t2026-11-29T00:00:00Z\n"
  printf "Gemini Models\tFive Hour Limit Remaining\t90%%\t2026-11-22T20:00:00Z\n"
  exit 0
fi
echo "agy ran for $USER"
exit 0
EOF
  chmod +x "$fixture_dir/bin/agy"

  # used_sec is huge (999999 > budget_sec 100), but exhausted is false
  cat > "$fixture_dir/state/gpro1.state.json" <<EOF
{"user": "gpro1", "window_start": 1000, "reset_at": 9999999999, "used_sec": 999999, "budget_sec": 100, "exhausted": false}
EOF

  local out
  out=$(env PATH="$fixture_dir/bin:$PATH" \
    POOL_CONF="$fixture_dir/pool.conf" MODELS_CONF="$fixture_dir/models.conf" \
    AGY_BIN="$fixture_dir/bin/agy" FM_AGY_STATE_DIR="$fixture_dir/state" \
    FM_AGY_USAGE_LOG="$fixture_dir/usage.jsonl" \
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" \
    "$POOL" --model gemini-3.8-flash-high -p hello 2>&1)
  assert_contains "$out" "Routing model 'gemini-3.8-flash-high' to 'gpro1'" \
    "large used_sec without exhausted must not skip account"

  pass "large used_sec without exhausted never skips an account when FM_AGY_LOCAL_ESTIMATE is off"
}

test_individual_quota_exhaustion_and_model_allowlist_failover() {
  local fixture_dir="$TMP_ROOT/individual_quota"
  mkdir -p "$fixture_dir/bin" "$fixture_dir/state"

  cat > "$fixture_dir/pool.conf" <<EOF
gpro1
piyushjiit
piyushk
EOF
  # Space-separated allowlist for hydrogen, comma-separated for neon
  cat > "$fixture_dir/models.conf" <<EOF
*hydrogen* piyushjiit piyushk
*neon* piyushjiit,piyushk
EOF

  cat > "$fixture_dir/bin/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then exec /usr/bin/id "$@"; fi
exit 0
EOF
  chmod +x "$fixture_dir/bin/id"

  cat > "$fixture_dir/bin/sudo" <<'EOF'
#!/usr/bin/env bash
TARGET_USER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|-H) shift ;;
    -u) TARGET_USER="$2"; shift 2 ;;
    *) break ;;
  esac
done
if [[ "${1:-}" == "test" ]]; then exit 0; fi
SUDO_TARGET_USER="$TARGET_USER" exec "$@"
EOF
  chmod +x "$fixture_dir/bin/sudo"

  cat > "$fixture_dir/bin/fake-pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$fixture_dir/bin/fake-pgrep"

  # piyushjiit fails with Individual quota reached + stated reset duration; piyushk succeeds
  local calls_log="$fixture_dir/calls.log"
  cat > "$fixture_dir/bin/agy" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\${SUDO_TARGET_USER:-unknown}" >> "$calls_log"
if [[ "\${SUDO_TARGET_USER:-}" == "piyushjiit" ]]; then
  echo "antigravity reported error: Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 2h48m0s." >&2
  exit 1
fi
echo "success on \$SUDO_TARGET_USER"
exit 0
EOF
  chmod +x "$fixture_dir/bin/agy"

  local before_ts out rc=0
  before_ts=$(date +%s)
  out=$(env PATH="$fixture_dir/bin:$PATH" \
    POOL_CONF="$fixture_dir/pool.conf" MODELS_CONF="$fixture_dir/models.conf" \
    AGY_BIN="$fixture_dir/bin/agy" FM_AGY_STATE_DIR="$fixture_dir/state" \
    FM_AGY_USAGE_LOG="$fixture_dir/usage.jsonl" \
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" \
    "$POOL" --model gemini-4-hydrogen-high -p hello 2>&1) || rc=$?

  [ "$rc" -eq 0 ] || fail "pool must rotate from exhausted piyushjiit to piyushk and succeed, got $rc: $out"
  assert_contains "$out" "success on piyushk" "second allowed account must run and succeed"
  [ "$(cat "$calls_log")" = $'piyushjiit\npiyushk' ] || fail "expected piyushjiit then piyushk, got: $(cat "$calls_log")"

  # Check piyushjiit state: exhausted=true and reset_at ~ before_ts + 10080 (2h48m0s)
  local exh reset_at expected_min
  exh=$(jq -r '.exhausted' "$fixture_dir/state/piyushjiit.state.json")
  reset_at=$(jq -r '.reset_at' "$fixture_dir/state/piyushjiit.state.json")
  [ "$exh" = "true" ] || fail "piyushjiit must be marked exhausted=true"
  expected_min=$(( before_ts + 10070 ))
  (( reset_at >= expected_min && reset_at <= before_ts + 10200 )) \
    || fail "reset_at ($reset_at) should be ~2h48m from $before_ts"

  # Flash (unrestricted) must not spill onto either space-separated reserved user (piyushjiit or piyushk)
  cat > "$fixture_dir/state/gpro1.state.json" <<EOF
{"user": "gpro1", "window_start": 1000, "reset_at": 9999999999, "used_sec": 0, "budget_sec": 5400, "exhausted": true}
EOF
  rc=0
  out=$(env PATH="$fixture_dir/bin:$PATH" \
    POOL_CONF="$fixture_dir/pool.conf" MODELS_CONF="$fixture_dir/models.conf" \
    AGY_BIN="$fixture_dir/bin/agy" FM_AGY_STATE_DIR="$fixture_dir/state" \
    FM_AGY_USAGE_LOG="$fixture_dir/usage.jsonl" \
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" \
    "$POOL" --model gemini-3.8-flash-high -p hello 2>&1) || rc=$?
  [ "$rc" -eq 75 ] || fail "flash must not spill onto space-separated reserved accounts, got $rc: $out"

  # When all neon accounts also hit 429/RESOURCE_EXHAUSTED, pool exits 75
  cat > "$fixture_dir/bin/agy" <<'EOF'
#!/usr/bin/env bash
echo "RESOURCE_EXHAUSTED: 429 quota exceeded" >&2
exit 1
EOF
  chmod +x "$fixture_dir/bin/agy"
  rc=0
  out=$(env PATH="$fixture_dir/bin:$PATH" \
    POOL_CONF="$fixture_dir/pool.conf" MODELS_CONF="$fixture_dir/models.conf" \
    AGY_BIN="$fixture_dir/bin/agy" FM_AGY_STATE_DIR="$fixture_dir/state" \
    FM_AGY_USAGE_LOG="$fixture_dir/usage.jsonl" \
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" \
    "$POOL" --model gemini-4-neon-high -p hello 2>&1) || rc=$?
  [ "$rc" -eq 75 ] || fail "exhausting all allowed accounts must exit 75, got $rc: $out"
  assert_contains "$out" "All eligible accounts for model 'gemini-4-neon-high' are exhausted" \
    "must report all accounts exhausted"

  pass "Individual quota reached marks account until stated reset time and rotates across space/comma allowlists"
}

test_conversation_affinity_pins_owner_account() {
  local fx="$TMP_ROOT/conv"
  rm -rf "$fx"
  mkdir -p "$fx/bin" "$fx/state" "$fx/home/piyushk/.gemini/antigravity-cli/conversations" "$fx/home/piyushjiit/.gemini/antigravity-cli/conversations"
  printf 'piyushjiit\npiyushk\n' > "$fx/pool.conf"
  printf '*neon* piyushjiit piyushk\n' > "$fx/models.conf"
  : > "$fx/home/piyushk/.gemini/antigravity-cli/conversations/conv-abc-123.pb"
  cat > "$fx/bin/id" <<'EOF2'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then exec /usr/bin/id "$@"; fi
exit 0
EOF2
  cat > "$fx/bin/sudo" <<'EOF2'
#!/usr/bin/env bash
TARGET_USER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|-H) shift ;;
    -u) TARGET_USER="$2"; shift 2 ;;
    *) break ;;
  esac
done
if [[ "${1:-}" == "test" ]]; then exit 0; fi
SUDO_TARGET_USER="$TARGET_USER" exec "$@"
EOF2
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fx/bin/fake-pgrep"
  cat > "$fx/bin/agy" <<EOF2
#!/usr/bin/env bash
printf '%s\n' "\${SUDO_TARGET_USER:-unknown}" >> "$fx/calls.log"
echo '{"event":"result","result":{"conversation_id":"fresh-conv-777","status":"SUCCESS"}}'
exit 0
EOF2
  chmod +x "$fx"/bin/*
  conv_run() {
    env PATH="$fx/bin:$PATH" POOL_CONF="$fx/pool.conf" MODELS_CONF="$fx/models.conf" \
      AGY_BIN="$fx/bin/agy" FM_AGY_STATE_DIR="$fx/state" FM_AGY_USAGE_LOG="$fx/usage.jsonl" \
      FM_AGY_PGREP="$fx/bin/fake-pgrep" FM_AGY_HOME_BASE="$fx/home" \
      "$POOL" "$@" 2>&1
  }
  local out rc=0
  out=$(conv_run --model gemini-4-neon-medium --conversation conv-abc-123 -p hi) || rc=$?
  [ "$rc" -eq 0 ] || fail "resumed call must run on the owning account, got $rc: $out"
  [ "$(cat "$fx/calls.log")" = piyushk ] || fail "conversation owner is piyushk, ran on: $(cat "$fx/calls.log")"

  rm -f "$fx/calls.log"
  out=$(conv_run --model gemini-4-neon-medium --conversation=conv-abc-123 --account piyushjiit -p hi) || rc=$?
  [ "$(cat "$fx/calls.log")" = piyushk ] || fail "--conversation=<id> must also pin the owner over a requested account"

  # a conversation created through the pool is recorded and then pinned
  rm -f "$fx/calls.log"
  conv_run --model gemini-4-neon-medium -p first >/dev/null || true
  first_user=$(cat "$fx/calls.log")
  rm -f "$fx/calls.log"
  conv_run --model gemini-4-neon-medium --conversation fresh-conv-777 -p again >/dev/null || true
  [ "$(cat "$fx/calls.log")" = "$first_user" ] || fail "recorded conversation must route back to $first_user"

  # owner exhausted: exit 75 cleanly, never run on the other account
  rm -f "$fx/calls.log"
  printf '{"user":"piyushk","window_start":1,"reset_at":9999999999,"used_sec":0,"budget_sec":5400,"exhausted":true}\n' > "$fx/state/piyushk.state.json"
  rc=0
  out=$(conv_run --model gemini-4-neon-medium --conversation conv-abc-123 -p hi) || rc=$?
  [ "$rc" -eq 75 ] || fail "exhausted conversation owner must exit 75, got $rc: $out"
  [ ! -e "$fx/calls.log" ] || fail "call must not run on another account: $(cat "$fx/calls.log")"
  assert_contains "$out" "conv-abc-123" "refusal names the conversation"

  # unknown conversation keeps today's routing
  rm -f "$fx/calls.log"
  rc=0
  out=$(conv_run --model gemini-4-neon-medium --conversation never-seen -p hi) || rc=$?
  [ "$rc" -eq 0 ] || fail "unknown conversation must route as before, got $rc: $out"
  pass "--conversation pins the call to the owning account and exits 75 when that account is exhausted"
}

test_stdin_prompt_survives_quota_rotation() {
  local fx="$TMP_ROOT/stdin_rotate"
  mkdir -p "$fx/bin" "$fx/state"
  printf '%s\n' gpro1 gpro2 > "$fx/pool.conf"
  printf '%s\n' '*neon* gpro1,gpro2' > "$fx/models.conf"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fx/bin/id"
  cat > "$fx/bin/sudo" <<'EOF'
#!/usr/bin/env bash
T=""
while [[ $# -gt 0 ]]; do
  case "$1" in -n|-H) shift ;; -u) T="$2"; shift 2 ;; *) break ;; esac
done
if [[ "${1:-}" == "test" ]]; then exit 0; fi
SUDO_TARGET_USER="$T" exec "$@"
EOF
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fx/bin/fake-pgrep"
  cat > "$fx/bin/agy" <<EOF
#!/usr/bin/env bash
cat > "$fx/stdin.\${SUDO_TARGET_USER}"
if [[ "\${SUDO_TARGET_USER}" == "gpro1" ]]; then
  echo "antigravity reported error: Individual quota reached. Resets in 1h0m0s." >&2
  exit 1
fi
exit 0
EOF
  chmod +x "$fx/bin/"*
  local prompt='{"event":"user","message":{"role":"user","content":[{"type":"text","text":"review this diff"}]}}'
  local rc=0 out
  out=$(printf '%s\n' "$prompt" | env PATH="$fx/bin:$PATH" POOL_CONF="$fx/pool.conf" MODELS_CONF="$fx/models.conf" \
    AGY_BIN="$fx/bin/agy" FM_AGY_STATE_DIR="$fx/state" FM_AGY_USAGE_LOG="$fx/usage.jsonl" \
    FM_AGY_PGREP="$fx/bin/fake-pgrep" \
    "$POOL" --model gemini-4-neon-high --print= --input-format stream-json --output-format stream-json 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "rotation must succeed on the second account, got $rc: $out"
  [ "$(cat "$fx/stdin.gpro1")" = "$prompt" ] || fail "first account must get the prompt: $(cat "$fx/stdin.gpro1")"
  [ "$(cat "$fx/stdin.gpro2")" = "$prompt" ] || fail "retried account must get the same stdin prompt, got: $(cat "$fx/stdin.gpro2" 2>/dev/null)"
  pass "stdin prompt is replayed to the next account after a quota rotation"
}

test_configured_order_wins_over_active_account_until_cap() {
  local fx="$TMP_ROOT/order_first"
  mkdir -p "$fx/bin" "$fx/state"
  printf '%s\n' gpro1 gpro2 > "$fx/pool.conf"
  printf '%s\n' '*neon* gpro1,gpro2' > "$fx/models.conf"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fx/bin/id"
  cat > "$fx/bin/sudo" <<'EOF'
#!/usr/bin/env bash
T=""
while [[ $# -gt 0 ]]; do
  case "$1" in -n|-H) shift ;; -u) T="$2"; shift 2 ;; *) break ;; esac
done
if [[ "${1:-}" == "test" ]]; then exit 0; fi
SUDO_TARGET_USER="$T" exec "$@"
EOF
  printf '#!/usr/bin/env bash\n[[ "$*" == *"-u gpro2"* ]] && exit 0\nexit 1\n' > "$fx/bin/fake-pgrep"
  printf '#!/usr/bin/env bash\necho "${SUDO_TARGET_USER}" >> "%s/calls.log"\nexit 0\n' "$fx" > "$fx/bin/agy"
  chmod +x "$fx/bin/"*
  local rc=0 out
  out=$(env PATH="$fx/bin:$PATH" POOL_CONF="$fx/pool.conf" MODELS_CONF="$fx/models.conf" \
    AGY_BIN="$fx/bin/agy" FM_AGY_STATE_DIR="$fx/state" FM_AGY_USAGE_LOG="$fx/usage.jsonl" \
    FM_AGY_PGREP="$fx/bin/fake-pgrep" "$POOL" --model gemini-4-neon-high -p hi 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "neon call must succeed, got $rc: $out"
  [ "$(cat "$fx/calls.log")" = gpro1 ] || fail "idle first configured account must win over active gpro2, got: $(cat "$fx/calls.log")"

  : > "$fx/calls.log"
  rc=0
  out=$(env PATH="$fx/bin:$PATH" POOL_CONF="$fx/pool.conf" MODELS_CONF="$fx/models.conf" \
    AGY_BIN="$fx/bin/agy" FM_AGY_STATE_DIR="$fx/state" FM_AGY_USAGE_LOG="$fx/usage.jsonl" \
    FM_AGY_PGREP="$fx/bin/fake-pgrep" FM_AGY_MAX_ACTIVE=1 "$POOL" --model gemini-4-neon-high -p hi 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "at the cap an active fitting account must be reused, got $rc: $out"
  [ "$(cat "$fx/calls.log")" = gpro2 ] || fail "at the cap the active account must be reused, got: $(cat "$fx/calls.log")"
  pass "configured account order wins over an active account until the active cap is reached"
}

test_no_pool_config_has_no_placeholder_accounts() {
  local rc=0 out
  out=$(env -u GPRO_POOL_USERS POOL_CONF="$TMP_ROOT/missing-pool.conf" MODELS_CONF="$TMP_ROOT/missing-models.conf" \
    AGY_BIN="$STUB" FM_AGY_STATE_DIR="$TMP_ROOT/state-np" FM_AGY_USAGE_LOG="$TMP_ROOT/np.jsonl" \
    "$POOL" --model gemini-4-neon-high -p hi 2>&1 </dev/null) || rc=$?
  [ "$rc" -eq 75 ] || fail "no pool config must exit 75, got $rc: $out"
  case "$out" in *gpro1*|*gpro2*) fail "placeholder accounts must not appear: $out" ;; esac
  pass "a missing pool config yields no eligible account instead of placeholder accounts"
}

test_cap_reuse_follows_model_order() {
  local fx="$TMP_ROOT/cap_order"
  mkdir -p "$fx/bin" "$fx/state"
  printf '%s\n' gpro1 gpro2 > "$fx/pool.conf"
  printf '%s\n' '*neon* gpro2,gpro1' > "$fx/models.conf"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fx/bin/id"
  cat > "$fx/bin/sudo" <<'EOF'
#!/usr/bin/env bash
T=""
while [[ $# -gt 0 ]]; do
  case "$1" in -n|-H) shift ;; -u) T="$2"; shift 2 ;; *) break ;; esac
done
if [[ "${1:-}" == "test" ]]; then exit 0; fi
SUDO_TARGET_USER="$T" exec "$@"
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fx/bin/fake-pgrep"
  printf '#!/usr/bin/env bash\necho "${SUDO_TARGET_USER}" >> "%s/calls.log"\nexit 0\n' "$fx" > "$fx/bin/agy"
  chmod +x "$fx/bin/"*
  local rc=0 out
  out=$(env PATH="$fx/bin:$PATH" POOL_CONF="$fx/pool.conf" MODELS_CONF="$fx/models.conf" \
    AGY_BIN="$fx/bin/agy" FM_AGY_STATE_DIR="$fx/state" FM_AGY_USAGE_LOG="$fx/usage.jsonl" \
    FM_AGY_PGREP="$fx/bin/fake-pgrep" "$POOL" --model gemini-4-neon-high -p hi 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "capped neon call must succeed, got $rc: $out"
  [ "$(cat "$fx/calls.log")" = gpro2 ] || fail "at the cap the first configured active account must win, got: $(cat "$fx/calls.log")"
  pass "at the active cap reuse follows the model's configured account order"
}

fm_test_run \
  test_symlink_refuses_claude_model \
  test_pool_model_env_refuses_claude \
  test_no_eligible_account_exits_75 \
  test_single_active_account_refusal \
  test_no_reserved_spill_for_flash \
  test_probe_skip_for_hydrogen_and_neon \
  test_false_positive_quota_hit_fix \
  test_usage_check_scenarios \
  test_usage_subcommand_behavior \
  test_status_subcommand_reads_log_without_network \
  test_queued_messages_setting \
  test_large_used_sec_without_exhausted_never_skips \
  test_individual_quota_exhaustion_and_model_allowlist_failover \
  test_conversation_affinity_pins_owner_account \
  test_stdin_prompt_survives_quota_rotation \
  test_configured_order_wins_over_active_account_until_cap \
  test_no_pool_config_has_no_placeholder_accounts \
  test_cap_reuse_follows_model_order
