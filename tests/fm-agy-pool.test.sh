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
unset FM_AGY_USER

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
if [[ "${1:-}" == "models" ]]; then
  printf "Fetching available models...\n"
  printf "gemini-3.8-flash-high\tGemini 3.8 Flash (High)\n"
  exit 0
fi
if [[ "${1:-}" == "-p" && "${2:-}" == "/usage" ]]; then
  echo "usage:${SUDO_TARGET_USER:-unknown}" >> "${FM_TEST_USAGE_LOG_FILE:-/tmp/agy_test_usage.log}"
  printf "Gemini Models\tWeekly Limit Remaining\t90%%\t2026-11-29T00:00:00Z\n"
  printf "Gemini Models\tFive Hour Limit Remaining\t90%%\t2026-11-22T20:00:00Z\n"
  exit 0
fi
echo "run:${SUDO_TARGET_USER:-unknown}" >> "${FM_TEST_USAGE_LOG_FILE:-/tmp/agy_test_usage.log}"
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
    FM_AGY_MAX_ACTIVE=1 FM_AGY_PACING_SEC=0 \
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
    FM_AGY_MAX_ACTIVE=1 FM_AGY_PACING_SEC=0 \
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
    FM_AGY_PACING_SEC=0 \
    "$POOL" --user gpro2 -p hello 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "default cap=2 must allow a second active account, got $rc: $err"
  : > "$usage_calls"
  : > "$fixture_dir/usage.jsonl"

  # Concurrent worker on same active account (gpro1) is allowed and records a
  # live start reading for that same account
  rc=0
  err=$(env PATH="$fixture_dir/bin:$PATH" \
    POOL_CONF="$fixture_dir/pool.conf" MODELS_CONF="$fixture_dir/models.conf" \
    AGY_BIN="$fixture_dir/bin/agy" FM_AGY_STATE_DIR="$fixture_dir/state" \
    FM_AGY_USAGE_LOG="$fixture_dir/usage.jsonl" \
    FM_TEST_USAGE_LOG_FILE="$usage_calls" \
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" \
    FM_AGY_PACING_SEC=0 \
    "$POOL" --user gpro1 -p hello 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "concurrent run on same active account must succeed, got $rc: $err"
  [ "$(head -n 1 "$usage_calls")" = "usage:gpro1" ] \
    || fail "active account reuse must take one live /usage reading for its own account, got: $(cat "$usage_calls")"
  [ "$(sed -n 2p "$usage_calls")" = "run:gpro1" ] \
    || fail "active account reuse must still run on gpro1 after the reading, got: $(cat "$usage_calls")"
  local start_chk
  start_chk=$(jq -rs '[.[] | select(.event == "usage_check")] | last | .user + "|" + .decision + "|" + (.gemini_min_pct|tostring)' "$fixture_dir/usage.jsonl")
  [ "$start_chk" = "gpro1|start|90" ] \
    || fail "active account reuse must log the live start reading for gpro1, got: $start_chk"
  assert_contains "$err" "(90% remaining" "route line must print the live reading used for the decision"

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
T=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|-H) shift ;;
    -u) T="$2"; shift 2 ;;
    *) break ;;
  esac
done
if [[ "${1:-}" == "test" ]]; then exit 0; fi
SUDO_TARGET_USER="$T" exec "$@"
EOF
  chmod +x "$fixture_dir/bin/sudo"

  cat > "$fixture_dir/bin/agy" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "models" ]]; then
  printf "Fetching available models...\n"
  if [[ "${SUDO_TARGET_USER:-}" == "piyushjiit" ]]; then
    printf "gemini-4-neon-high\tGemini 4 Neon (High)\n"
    printf "gemini-4-hydrogen-high\tGemini 4 Hydrogen (High)\n"
    printf "gemini-3.8-flash-high\tGemini 3.8 Flash (High)\n"
  else
    printf "gemini-3.8-flash-high\tGemini 3.8 Flash (High)\n"
    printf "gemini-4-hydrogen-high\tGemini 4 Hydrogen (High)\n"
  fi
  exit 0
fi
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

  # 1. With gpro1 healthy, Flash prefers non-reserved gpro1 (even if piyushjiit is earlier in pool.conf)
  printf 'piyushjiit\ngpro1\n' > "$fixture_dir/pool.conf"
  local out rc=0
  out=$(env PATH="$fixture_dir/bin:$PATH" \
    POOL_CONF="$fixture_dir/pool.conf" MODELS_CONF="$fixture_dir/models.conf" \
    AGY_BIN="$fixture_dir/bin/agy" FM_AGY_STATE_DIR="$fixture_dir/state" \
    FM_AGY_USAGE_LOG="$fixture_dir/usage.jsonl" \
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" FM_AGY_PACING_SEC=0 \
    "$POOL" --model gemini-3.8-flash-high -p hello 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "Flash must prefer non-reserved gpro1, got $rc: $out"
  assert_contains "$out" "Routing model 'gemini-3.8-flash-high' to 'gpro1'" "Flash prefers non-reserved gpro1"

  # 2. When non-reserved gpro1 is exhausted, Flash falls back to reserved piyushjiit
  cat > "$fixture_dir/state/gpro1.state.json" <<EOF
{"user": "gpro1", "window_start": 1000, "reset_at": 9999999999, "used_sec": 100, "budget_sec": 100, "exhausted": true}
EOF
  rc=0
  out=$(env PATH="$fixture_dir/bin:$PATH" \
    POOL_CONF="$fixture_dir/pool.conf" MODELS_CONF="$fixture_dir/models.conf" \
    AGY_BIN="$fixture_dir/bin/agy" FM_AGY_STATE_DIR="$fixture_dir/state" \
    FM_AGY_USAGE_LOG="$fixture_dir/usage.jsonl" \
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" FM_AGY_PACING_SEC=0 \
    "$POOL" --model gemini-3.8-flash-high -p hello 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "Flash must fall back to reserved piyushjiit when non-reserved exhausted, got $rc: $out"
  assert_contains "$out" "Routing model 'gemini-3.8-flash-high' to 'piyushjiit'" "Flash falls back to reserved piyushjiit"

  # 3. When reserved piyushjiit is also exhausted, Flash exits 75
  cat > "$fixture_dir/state/piyushjiit.state.json" <<EOF
{"user": "piyushjiit", "window_start": 1000, "reset_at": 9999999999, "used_sec": 100, "budget_sec": 100, "exhausted": true}
EOF
  rc=0
  out=$(env PATH="$fixture_dir/bin:$PATH" \
    POOL_CONF="$fixture_dir/pool.conf" MODELS_CONF="$fixture_dir/models.conf" \
    AGY_BIN="$fixture_dir/bin/agy" FM_AGY_STATE_DIR="$fixture_dir/state" \
    FM_AGY_USAGE_LOG="$fixture_dir/usage.jsonl" \
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" FM_AGY_PACING_SEC=0 \
    "$POOL" --model gemini-3.8-flash-high -p hello 2>&1) || rc=$?

  [ "$rc" -eq 75 ] || fail "Flash model must exit 75 when all accounts exhausted, got $rc: $out"
  assert_contains "$out" "No eligible account" "must say no eligible account"

  pass "Flash prefers non-reserved accounts and falls back to reserved only when none can serve"
}

test_probe_skip_for_hydrogen_and_neon() {
  local d="$TMP_ROOT/probe" out rc now_ts
  mkdir -p "$d/sd/agy-pool" "$d/state"
  now_ts=$(date +%s)
  printf '#!/usr/bin/env bash\necho ran >> "%s/models-ran"\necho gemini-3.8-flash-high\n' "$d" > "$d/agy"
  chmod +x "$d/agy"
  ln -sf "$POOL" "$d/sd/agy-pool/agy"
  printf 'gpro1\n' > "$d/pool.conf"

  run_validate() {
    rm -f "$d/models-ran"
    out=$(SCRIPT_DIR="$d/sd" POOL_CONF="$d/pool.conf" FM_AGY_STATE_DIR="$d/state" AGY_BIN="$d/agy" bash -c '
      . "'"$ROOT"'/bin/fm-timeout-lib.sh"
      eval "$(sed -n "/^agy_model_validate() {/,/^}/p" "'"$ROOT"'/bin/fm-spawn.sh")"
      agy_model_validate "$1" "$2" "${3:-}"' _ "$1" "$2" "${3:-}" 2>&1); rc=$?
  }

  # Plain agy still runs `agy models` live and refuses unlisted ids
  run_validate "$d/agy" gemini-4-neon-typo
  [ "$rc" -ne 0 ] || fail "plain agy must refuse an unlisted neon id"
  assert_contains "$out" "is not listed by 'agy models'" "plain agy lost its listing check"
  [ -e "$d/models-ran" ] || fail "plain agy must run the listing probe"

  # Pool launcher never runs live `agy models`; missing catalog allows with notice (read-only)
  rm -rf "$d/state"
  run_validate "$d/sd/agy-pool/agy" gemini-4-neon-medium
  [ "$rc" -eq 0 ] || fail "pool launcher must allow unknown catalog with notice (rc=$rc): $out"
  assert_contains "$out" "unknown" "missing catalog must print unknown notice"
  [ ! -e "$d/models-ran" ] || fail "pool launcher probe must never run live agy models"
  [ ! -e "$d/state" ] || fail "pool launcher probe must stay read-only"

  # Fresh catalog on pool launcher allows listed models and refuses unlisted ones (including neon/hydrogen)
  mkdir -p "$d/state"
  printf '{"user":"gpro1","fetched_at":%s,"models":["gemini-3.8-flash-high","gemini-4-hydrogen-high"]}\n' "$now_ts" > "$d/state/gpro1.models.json"
  run_validate "$d/sd/agy-pool/agy" gemini-4-hydrogen-high gpro1
  [ "$rc" -eq 0 ] || fail "fresh catalog listing hydrogen must pass (rc=$rc): $out"
  run_validate "$d/sd/agy-pool/agy" gemini-4-neon-medium gpro1
  [ "$rc" -ne 0 ] || fail "fresh catalog omitting neon must refuse (rc=$rc): $out"
  assert_contains "$out" "is not listed in pool account 'gpro1' cached catalog" "refusal must name missing model"
  [ ! -e "$d/models-ran" ] || fail "pool launcher probe must never run live agy models"

  pass "pool launcher probe validates against cached catalogs read-only with no Hydrogen/Neon skip"
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
if [[ "${1:-}" == "models" ]]; then
  printf "gemini-3.8-flash-high\tGemini 3.8 Flash (High)\n"
  exit 0
fi
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
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" FM_AGY_PACING_SEC=0 \
    "$POOL" --model gemini-3.8-flash-high -p hello >/dev/null 2>&1

  local exh
  exh=$(jq -r '.exhausted' "$fixture_dir/state/gpro1.state.json")
  [ "$exh" = "false" ] || fail "middle-of-log 429 must not mark account exhausted"

  # Exit 42 logs quota_hit as suspicion in usage log, but must not mark account exhausted in state file
  cat > "$fixture_dir/bin/agy" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "models" ]]; then
  printf "gemini-3.8-flash-high\tGemini 3.8 Flash (High)\n"
  exit 0
fi
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
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" FM_AGY_PACING_SEC=0 \
    "$POOL" --model gemini-3.8-flash-high -p hello >/dev/null 2>&1 || true

  exh=$(jq -r '.exhausted' "$fixture_dir/state/gpro1.state.json")
  [ "$exh" = "false" ] || fail "end-of-session exit 42 must not mark account exhausted in state file"
  local last_quota_hit
  last_quota_hit=$(jq -s '[.[] | select(has("quota_hit"))] | last | .quota_hit' "$fixture_dir/usage.jsonl")
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
if [[ "\${1:-}" == "models" ]]; then
  printf "gemini-3.8-flash-high\tGemini 3.8 Flash (High)\n"
  exit 0
fi
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
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" FM_AGY_PACING_SEC=0 \
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
if [[ "${1:-}" == "models" ]]; then
  printf "gemini-3.8-flash-high\tGemini 3.8 Flash (High)\n"
  exit 0
fi
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
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" FM_AGY_PACING_SEC=0 \
    "$POOL" --model gemini-3.8-flash-high -p hello 2>&1)
  assert_contains "$out" "Routing model 'gemini-3.8-flash-high' to 'gpro1'" "above floor routes to gpro1"
  assert_contains "$out" "(89% remaining" "route line must print the live reading used for the decision"

  # Verify usage_check logged "start" for gpro1
  local start_count
  start_count=$(jq -s '[.[] | select(.event == "usage_check" and .decision == "start" and .user == "gpro1")] | length' "$fixture_dir/usage.jsonl")
  [ "$start_count" -ge 1 ] || fail "usage log must record usage_check start event for gpro1"

  # Case B: Below floor on gpro1 (10% 5-hour), normal on gpro2 (89%) -> gpro1 marked exhausted, switches to gpro2
  cat > "$fixture_dir/bin/agy" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "models" ]]; then
  printf "gemini-3.8-flash-high\tGemini 3.8 Flash (High)\n"
  exit 0
fi
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
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" FM_AGY_PACING_SEC=0 \
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
if [[ "${1:-}" == "models" ]]; then
  printf "gemini-3.8-flash-high\tGemini 3.8 Flash (High)\n"
  exit 0
fi
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
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" FM_AGY_PACING_SEC=0 \
    "$POOL" --model gemini-3.8-flash-high -p hello 2>&1)
  assert_contains "$out" "Routing model 'gemini-3.8-flash-high' to 'gpro2'" "subsequent run directly selects gpro2"

  # Case D: Unparsable /usage output -> treated as unknown, starts on account
  rm -f "$fixture_dir/state"/*.json "$fixture_dir/state/last-active"
  : > "$fixture_dir/usage.jsonl"
  cat > "$fixture_dir/bin/agy" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "models" ]]; then
  printf "gemini-3.8-flash-high\tGemini 3.8 Flash (High)\n"
  exit 0
fi
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
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" FM_AGY_PACING_SEC=0 \
    "$POOL" --model gemini-3.8-flash-high -p hello 2>&1)
  assert_contains "$out" "Routing model 'gemini-3.8-flash-high' to 'gpro1'" "unparsable usage treated as unknown and starts on gpro1"
  assert_contains "$out" "(unknown remaining" "route line must say unknown when the live read gave no reading"

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
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" FM_AGY_MAX_ACTIVE=1 \
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

  # Pre-populate usage.jsonl with known check entries and cached catalogs
  local now_ts
  now_ts=$(date +%s)
  printf '{"user":"gpro1","fetched_at":%s,"models":["gemini-3.8-flash-high","gemini-4-hydrogen-high"]}\n' "$now_ts" > "$fixture_dir/state/gpro1.models.json"
  printf '{"user":"piyushjiit","fetched_at":%s,"models":["gemini-4-neon-high","gemini-4-hydrogen-high"]}\n' "$now_ts" > "$fixture_dir/state/piyushjiit.models.json"
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

  # gpro1: 89%, 2026-11-29T18:34:55Z, 2026-11-23T01:00:00Z, standard
  local gpro1_line
  gpro1_line=$(grep '^gpro1 ' <<<"$out")
  [ -n "$gpro1_line" ] || fail "missing gpro1 row in --status output: $out"
  assert_contains "$gpro1_line" "89%" "gpro1 must show 89%"
  assert_contains "$gpro1_line" "2026-11-29T18:34:55Z" "gpro1 must show reset"
  assert_contains "$gpro1_line" "2026-11-23T01:00:00Z" "gpro1 must show checked_at"
  assert_contains "$gpro1_line" "standard" "non-reserved cached account must show standard"

  # gpro2: 10% (skip), 2026-11-23T05:00:00Z, 2026-11-23T01:05:00Z
  local gpro2_line
  gpro2_line=$(grep '^gpro2 ' <<<"$out")
  [ -n "$gpro2_line" ] || fail "missing gpro2 row in --status output: $out"
  assert_contains "$gpro2_line" "10% (skip)" "gpro2 must show (skip)"
  assert_contains "$gpro2_line" "2026-11-23T05:00:00Z" "gpro2 must show reset"
  assert_contains "$gpro2_line" "2026-11-23T01:05:00Z" "gpro2 must show checked_at"

  # piyushjiit: unknown usage, reserved (neon) catalog
  local piyush_line
  piyush_line=$(grep '^piyushjiit ' <<<"$out")
  [ -n "$piyush_line" ] || fail "missing piyushjiit row in --status output: $out"
  assert_contains "$piyush_line" "unknown" "unprobed account must show unknown"
  assert_contains "$piyush_line" "reserved (neon)" "piyushjiit must show reserved (neon) from catalog"

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
if [[ "\${1:-}" == "models" ]]; then
  printf "gemini-3.8-flash-high\tGemini 3.8 Flash (High)\n"
  exit 0
fi
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
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" FM_AGY_PACING_SEC=0 \
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
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" FM_AGY_PACING_SEC=0 \
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
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" FM_AGY_PACING_SEC=0 \
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
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" FM_AGY_PACING_SEC=0 \
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
if [[ "${1:-}" == "models" ]]; then
  printf "gemini-3.8-flash-high\tGemini 3.8 Flash (High)\n"
  exit 0
fi
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
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" FM_AGY_PACING_SEC=0 \
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

  # piyushjiit fails with Individual quota reached + stated reset duration; piyushk succeeds.
  # gpro1 only lists Flash in this fixture so Hydrogen failover exercises piyushjiit -> piyushk.
  local calls_log="$fixture_dir/calls.log"
  cat > "$fixture_dir/bin/agy" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "models" ]]; then
  if [[ "\${SUDO_TARGET_USER:-}" == "gpro1" ]]; then
    printf "gemini-3.8-flash-high\tGemini 3.8 Flash (High)\n"
  else
    printf "gemini-4-neon-high\tGemini 4 Neon (High)\n"
    printf "gemini-4-hydrogen-high\tGemini 4 Hydrogen (High)\n"
  fi
  exit 0
fi
if [[ "\${1:-}" == "-p" && "\${2:-}" == "/usage" ]]; then
  printf "Gemini Models\tWeekly Limit Remaining\t90%%\t2026-11-29T00:00:00Z\n"
  printf "Gemini Models\tFive Hour Limit Remaining\t90%%\t2026-11-22T20:00:00Z\n"
  exit 0
fi
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
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" FM_AGY_PACING_SEC=0 \
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

  # Flash must not spill onto reserved accounts whose catalog omits Flash when gpro1 is exhausted
  cat > "$fixture_dir/state/gpro1.state.json" <<EOF
{"user": "gpro1", "window_start": 1000, "reset_at": 9999999999, "used_sec": 0, "budget_sec": 5400, "exhausted": true}
EOF
  rc=0
  out=$(env PATH="$fixture_dir/bin:$PATH" \
    POOL_CONF="$fixture_dir/pool.conf" MODELS_CONF="$fixture_dir/models.conf" \
    AGY_BIN="$fixture_dir/bin/agy" FM_AGY_STATE_DIR="$fixture_dir/state" \
    FM_AGY_USAGE_LOG="$fixture_dir/usage.jsonl" \
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" FM_AGY_PACING_SEC=0 \
    "$POOL" --model gemini-3.8-flash-high -p hello 2>&1) || rc=$?
  [ "$rc" -eq 75 ] || fail "flash must exit 75 when no eligible account supports it, got $rc: $out"

  # When all neon accounts also hit 429/RESOURCE_EXHAUSTED, pool exits 75
  cat > "$fixture_dir/bin/agy" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "models" ]]; then
  printf "gemini-4-neon-high\tGemini 4 Neon (High)\n"
  exit 0
fi
if [[ "${1:-}" == "-p" && "${2:-}" == "/usage" ]]; then
  printf "Gemini Models\tWeekly Limit Remaining\t90%%\t2026-11-29T00:00:00Z\n"
  printf "Gemini Models\tFive Hour Limit Remaining\t90%%\t2026-11-22T20:00:00Z\n"
  exit 0
fi
echo "RESOURCE_EXHAUSTED: 429 quota exceeded" >&2
exit 1
EOF
  chmod +x "$fixture_dir/bin/agy"
  rc=0
  out=$(env PATH="$fixture_dir/bin:$PATH" \
    POOL_CONF="$fixture_dir/pool.conf" MODELS_CONF="$fixture_dir/models.conf" \
    AGY_BIN="$fixture_dir/bin/agy" FM_AGY_STATE_DIR="$fixture_dir/state" \
    FM_AGY_USAGE_LOG="$fixture_dir/usage.jsonl" \
    FM_AGY_PGREP="$fixture_dir/bin/fake-pgrep" FM_AGY_PACING_SEC=0 \
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
if [[ "\${1:-}" == "models" ]]; then
  printf "gemini-4-neon-medium\tGemini 4 Neon (Medium)\n"
  exit 0
fi
if [[ "\${1:-}" == "-p" && "\${2:-}" == "/usage" ]]; then
  printf "Gemini Models\tWeekly Limit Remaining\t90%%\t2026-11-29T00:00:00Z\n"
  printf "Gemini Models\tFive Hour Limit Remaining\t90%%\t2026-11-22T20:00:00Z\n"
  exit 0
fi
printf '%s\n' "\${SUDO_TARGET_USER:-unknown}" >> "$fx/calls.log"
echo '{"event":"result","result":{"conversation_id":"fresh-conv-777","status":"SUCCESS"}}'
exit 0
EOF2
  chmod +x "$fx"/bin/*
  conv_run() {
    env PATH="$fx/bin:$PATH" POOL_CONF="$fx/pool.conf" MODELS_CONF="$fx/models.conf" \
      AGY_BIN="$fx/bin/agy" FM_AGY_STATE_DIR="$fx/state" FM_AGY_USAGE_LOG="$fx/usage.jsonl" \
      FM_AGY_PGREP="$fx/bin/fake-pgrep" FM_AGY_HOME_BASE="$fx/home" FM_AGY_PACING_SEC=0 \
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
if [[ "\${1:-}" == "models" ]]; then
  printf "gemini-4-neon-high\tGemini 4 Neon (High)\n"
  exit 0
fi
if [[ "\${1:-}" == "-p" && "\${2:-}" == "/usage" ]]; then
  printf "Gemini Models\tWeekly Limit Remaining\t90%%\t2026-11-29T00:00:00Z\n"
  printf "Gemini Models\tFive Hour Limit Remaining\t90%%\t2026-11-22T20:00:00Z\n"
  exit 0
fi
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
    FM_AGY_PGREP="$fx/bin/fake-pgrep" FM_AGY_PACING_SEC=0 \
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
  cat > "$fx/bin/agy" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "models" ]]; then
  printf "gemini-4-neon-high\tGemini 4 Neon (High)\n"
  exit 0
fi
if [[ "\${1:-}" == "-p" && "\${2:-}" == "/usage" ]]; then
  printf "Gemini Models\tWeekly Limit Remaining\t90%%\t2026-11-29T00:00:00Z\n"
  printf "Gemini Models\tFive Hour Limit Remaining\t90%%\t2026-11-22T20:00:00Z\n"
  exit 0
fi
echo "\${SUDO_TARGET_USER}" >> "$fx/calls.log"
exit 0
EOF
  chmod +x "$fx/bin/"*
  local rc=0 out
  out=$(env PATH="$fx/bin:$PATH" POOL_CONF="$fx/pool.conf" MODELS_CONF="$fx/models.conf" \
    AGY_BIN="$fx/bin/agy" FM_AGY_STATE_DIR="$fx/state" FM_AGY_USAGE_LOG="$fx/usage.jsonl" \
    FM_AGY_PGREP="$fx/bin/fake-pgrep" FM_AGY_PACING_SEC=0 "$POOL" --model gemini-4-neon-high -p hi 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "neon call must succeed, got $rc: $out"
  [ "$(cat "$fx/calls.log")" = gpro1 ] || fail "idle first eligible account must win over active gpro2, got: $(cat "$fx/calls.log")"

  : > "$fx/calls.log"
  rc=0
  out=$(env PATH="$fx/bin:$PATH" POOL_CONF="$fx/pool.conf" MODELS_CONF="$fx/models.conf" \
    AGY_BIN="$fx/bin/agy" FM_AGY_STATE_DIR="$fx/state" FM_AGY_USAGE_LOG="$fx/usage.jsonl" \
    FM_AGY_PGREP="$fx/bin/fake-pgrep" FM_AGY_MAX_ACTIVE=1 FM_AGY_PACING_SEC=0 "$POOL" --model gemini-4-neon-high -p hi 2>&1) || rc=$?
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
  : > "$fx/models.conf"
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
  cat > "$fx/bin/agy" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "models" ]]; then
  printf "gemini-4-neon-high\tGemini 4 Neon (High)\n"
  exit 0
fi
if [[ "\${1:-}" == "-p" && "\${2:-}" == "/usage" ]]; then
  printf "Gemini Models\tWeekly Limit Remaining\t90%%\t2026-11-29T00:00:00Z\n"
  printf "Gemini Models\tFive Hour Limit Remaining\t90%%\t2026-11-22T20:00:00Z\n"
  exit 0
fi
echo "\${SUDO_TARGET_USER}" >> "$fx/calls.log"
exit 0
EOF
  chmod +x "$fx/bin/"*
  local now_ts
  now_ts=$(date +%s)
  printf '{"user":"gpro1","fetched_at":%s,"models":["gemini-4-neon-high"]}\n' "$now_ts" > "$fx/state/gpro1.models.json"
  printf '{"user":"gpro2","fetched_at":%s,"models":["gemini-4-neon-high"]}\n' "$now_ts" > "$fx/state/gpro2.models.json"
  printf '{"user":"gpro1","window_start":1,"reset_at":0,"used_sec":0,"budget_sec":5400,"exhausted":false,"quota":{"Gemini Models":{"min_pct":45,"reset_at":0}}}\n' > "$fx/state/gpro1.state.json"
  printf '{"user":"gpro2","window_start":1,"reset_at":0,"used_sec":0,"budget_sec":5400,"exhausted":false,"quota":{"Gemini Models":{"min_pct":92,"reset_at":0}}}\n' > "$fx/state/gpro2.state.json"
  local rc=0 out
  out=$(env PATH="$fx/bin:$PATH" POOL_CONF="$fx/pool.conf" MODELS_CONF="$fx/models.conf" \
    AGY_BIN="$fx/bin/agy" FM_AGY_STATE_DIR="$fx/state" FM_AGY_USAGE_LOG="$fx/usage.jsonl" \
    FM_AGY_PGREP="$fx/bin/fake-pgrep" FM_AGY_PACING_SEC=0 "$POOL" --model gemini-4-neon-high -p hi 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "capped neon call must succeed, got $rc: $out"
  [ "$(cat "$fx/calls.log")" = gpro2 ] || fail "at the cap the higher-quota active account must win, got: $(cat "$fx/calls.log")"
  local at_cap_start
  at_cap_start=$(jq -rs '[.[] | select(.event == "usage_check")] | last | .user + "|" + .decision + "|" + (.gemini_min_pct|tostring)' "$fx/usage.jsonl")
  [ "$at_cap_start" = "gpro2|start|90" ] \
    || fail "at-cap reuse must take a live start reading on the reused account, got: $at_cap_start"
  pass "at the active cap reuse follows quota-ordered account priority and records its live start reading"
}

test_active_account_reuse_allows_uncertain_catalog() {
  local fx="$TMP_ROOT/active_uncertain"
  make_discovery_fixture "$fx" gpro1
  printf 'gemini-4-hydrogen-high\tGemini 4 Hydrogen (High)\n' > "$fx/models.default"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fx/bin/fake-pgrep"
  chmod +x "$fx/bin/fake-pgrep"
  printf '{"user":"gpro1","fetched_at":1,"models":["gemini-4-hydrogen-high"]}\n' > "$fx/state/gpro1.models.json"
  : > "$fx/fail_models"

  discovery_run "$fx" FM_AGY_MAX_ACTIVE=1 -- --model gemini-4-hydrogen-high -p hi
  [ "$RC" -eq 0 ] || fail "at the cap an active account with an uncertain catalog must be reused, got $RC: $OUT"
  [ "$(cat "$fx/run_calls.log" 2>/dev/null)" = gpro1 ] || fail "at the cap the active account must run, got: $(cat "$fx/run_calls.log" 2>/dev/null)"
  assert_contains "$OUT" "uncertain" "uncertain catalog must be reported"

  : > "$fx/run_calls.log"
  discovery_run "$fx" FM_AGY_MAX_ACTIVE=1 -- --user gpro1 --model gemini-4-hydrogen-high -p hi
  [ "$RC" -eq 0 ] || fail "an explicit active account with an uncertain catalog must be reused, got $RC: $OUT"
  [ "$(cat "$fx/run_calls.log" 2>/dev/null)" = gpro1 ] || fail "the explicit active account must run, got: $(cat "$fx/run_calls.log" 2>/dev/null)"

  pass "active-account reuse allows an uncertain catalog instead of exiting at the cap"
}

test_usage_follows_active_cap() {
  local fx="$TMP_ROOT/usage_cap"
  mkdir -p "$fx/bin" "$fx/state"
  printf '%s\n' gpro1 gpro2 gpro3 > "$fx/pool.conf"
  : > "$fx/models.conf"
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
  cat > "$fx/bin/agy" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-p" && "${2:-}" == "/usage" ]]; then
  printf "Gemini Models\tWeekly Limit Remaining\t95%%\t2026-11-29T12:00:00Z\n"
  printf "Gemini Models\tFive Hour Limit Remaining\t88%%\t2026-11-23T06:00:00Z\n"
fi
exit 0
EOF
  chmod +x "$fx/bin/"*
  local rc out
  run_usage() {  # <active csv> <target>
    # shellcheck disable=SC2016 # single quotes are intentional: the fixture script expands at run time
    printf '#!/usr/bin/env bash\nfor u in %s; do [[ "$*" == *"-u $u"* ]] && exit 0; done\nexit 1\n' "$(printf '%s' "$1" | tr ',' ' ')" > "$fx/bin/fake-pgrep"
    chmod +x "$fx/bin/fake-pgrep"
    rc=0
    out=$(env PATH="$fx/bin:$PATH" POOL_CONF="$fx/pool.conf" MODELS_CONF="$fx/models.conf" \
      AGY_BIN="$fx/bin/agy" FM_AGY_STATE_DIR="$fx/state" FM_AGY_USAGE_LOG="$fx/usage.jsonl" \
      FM_AGY_PGREP="$fx/bin/fake-pgrep" FM_AGY_PACING_SEC=0 "$POOL" --usage "$2" 2>&1) || rc=$?
  }
  run_usage gpro1,gpro2 gpro1
  [ "$rc" -eq 0 ] || fail "--usage on an active target must succeed at the cap, got $rc: $out"
  run_usage gpro1 gpro2
  [ "$rc" -eq 0 ] || fail "--usage on an inactive target under the cap must succeed, got $rc: $out"
  run_usage gpro1,gpro2 gpro3
  [ "$rc" -eq 75 ] || fail "--usage on an inactive target at the cap must exit 75, got $rc: $out"
  assert_contains "$out" "FM_AGY_MAX_ACTIVE" "refusal must name the cap"
  pass "--usage follows FM_AGY_MAX_ACTIVE: allowed for an active target or under the cap, refused otherwise"
}

test_forged_conversation_record_is_not_trusted() {
  local fx="$TMP_ROOT/conv_forged"
  mkdir -p "$fx/bin" "$fx/state" "$fx/home"
  printf 'piyushjiit\npiyushk\nother\n' > "$fx/pool.conf"
  printf '*neon* piyushjiit piyushk\n' > "$fx/models.conf"
  printf 'conv-forged-1\tevil\nconv-forged-2\tother\n' > "$fx/state/conversations.tsv"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fx/bin/id"
  cat > "$fx/bin/sudo" <<'EOF2'
#!/usr/bin/env bash
T=""
while [[ $# -gt 0 ]]; do
  case "$1" in -n|-H) shift ;; -u) T="$2"; shift 2 ;; *) break ;; esac
done
if [[ "${1:-}" == "test" ]]; then exit 0; fi
SUDO_TARGET_USER="$T" exec "$@"
EOF2
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fx/bin/fake-pgrep"
  cat > "$fx/bin/agy" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "models" ]]; then
  if [[ "\${SUDO_TARGET_USER:-}" == "other" ]]; then
    printf "gemini-3.8-flash-high\tGemini 3.8 Flash (High)\n"
  else
    printf "gemini-4-neon-medium\tGemini 4 Neon (Medium)\n"
  fi
  exit 0
fi
if [[ "\${1:-}" == "-p" && "\${2:-}" == "/usage" ]]; then
  printf "Gemini Models\tWeekly Limit Remaining\t90%%\t2026-11-29T00:00:00Z\n"
  printf "Gemini Models\tFive Hour Limit Remaining\t90%%\t2026-11-22T20:00:00Z\n"
  exit 0
fi
echo "\${SUDO_TARGET_USER}" >> "$fx/calls.log"
exit 0
EOF
  chmod +x "$fx"/bin/*
  local c rc
  for c in conv-forged-1 conv-forged-2; do
    rc=0
    env PATH="$fx/bin:$PATH" POOL_CONF="$fx/pool.conf" MODELS_CONF="$fx/models.conf" \
      AGY_BIN="$fx/bin/agy" FM_AGY_STATE_DIR="$fx/state" FM_AGY_USAGE_LOG="$fx/usage.jsonl" \
      FM_AGY_PGREP="$fx/bin/fake-pgrep" FM_AGY_HOME_BASE="$fx/home" FM_AGY_PACING_SEC=0 \
      "$POOL" --model gemini-4-neon-medium --conversation "$c" -p hi >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] || fail "$c must route normally, got $rc"
  done
  [ "$(sort -u "$fx/calls.log" | tr '\n' ' ')" = "piyushjiit " ] \
    || fail "forged owners must be ignored; calls went to: $(cat "$fx/calls.log")"
  pass "conversation records naming a non-pool or model-disallowed account are not trusted"
}

# Fixture for the account-naming and task-data checks: a fake id, a sudo that
# reports a pool account signed in unless the account is listed in
# $fx/unauth, a setfacl that logs its arguments, and a stub agy.
make_named_account_fixture() {
  local fx=$1 now_ts
  rm -rf "$fx"
  mkdir -p "$fx/bin" "$fx/state"
  printf '%s\n' gpro1 gpro2 gpro3 > "$fx/pool.conf"
  printf '%s\n' '*neon* gpro2,gpro3' > "$fx/models.conf"
  now_ts=$(date +%s)
  printf '{"user":"gpro1","fetched_at":%s,"models":["gemini-3.8-flash-low","gemini-3.8-flash-high","gemini-4-hydrogen-high"]}\n' "$now_ts" > "$fx/state/gpro1.models.json"
  printf '{"user":"gpro2","fetched_at":%s,"models":["gemini-3.8-flash-low","gemini-3.8-flash-high","gemini-4-hydrogen-high","gemini-4-neon-medium"]}\n' "$now_ts" > "$fx/state/gpro2.models.json"
  printf '{"user":"gpro3","fetched_at":%s,"models":["gemini-3.8-flash-low","gemini-3.8-flash-high","gemini-4-hydrogen-high","gemini-4-neon-medium"]}\n' "$now_ts" > "$fx/state/gpro3.models.json"
  : > "$fx/unauth"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fx/bin/id"
  cat > "$fx/bin/sudo" <<EOF2
#!/usr/bin/env bash
T=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in -n|-H) shift ;; -u) T="\$2"; shift 2 ;; *) break ;; esac
done
if [[ "\${1:-}" == "test" ]]; then ! grep -qx "\$T" "$fx/unauth"; exit \$?; fi
SUDO_TARGET_USER="\$T" exec "\$@"
EOF2
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/setfacl.log"\n' "$fx" > "$fx/bin/setfacl"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fx/bin/fake-pgrep"
  cat > "$fx/bin/agy" <<'EOF2'
#!/usr/bin/env bash
if [[ "${1:-}" == "models" ]]; then
  printf "gemini-3.8-flash-low\tGemini 3.8 Flash (Low)\n"
  printf "gemini-4-neon-medium\tGemini 4 Neon (Medium)\n"
  exit 0
fi
if [[ "${1:-}" == "-p" && "${2:-}" == "/usage" ]]; then
  printf "Gemini Models\tWeekly Limit Remaining\t90%%\t2026-11-29T00:00:00Z\n"
  printf "Gemini Models\tFive Hour Limit Remaining\t90%%\t2026-11-22T20:00:00Z\n"
  exit 0
fi
exit 0
EOF2
  chmod +x "$fx"/bin/*
}

named_account_run() {  # <fx> <args>...  -> sets RC and OUT
  local fx=$1; shift
  RC=0
  OUT=$(env PATH="$fx/bin:$PATH" POOL_CONF="$fx/pool.conf" MODELS_CONF="$fx/models.conf" \
    AGY_BIN="$fx/bin/agy" FM_AGY_STATE_DIR="$fx/state" FM_AGY_USAGE_LOG="$fx/usage.jsonl" \
    FM_AGY_PGREP="$fx/bin/fake-pgrep" FM_AGY_PACING_SEC=0 "$POOL" "$@" 2>&1) || RC=$?
}

test_check_account_validates_a_named_account() {
  local fx="$TMP_ROOT/check_account"
  make_named_account_fixture "$fx"
  named_account_run "$fx" --check-account gpro2 gemini-4-neon-medium
  [ "$RC" -eq 0 ] && [ "$OUT" = gpro2 ] || fail "listed, signed-in, allowed account must pass and print itself: rc=$RC $OUT"
  named_account_run "$fx" --check-account nobody gemini-4-neon-medium
  [ "$RC" -eq 1 ] || fail "unknown account must refuse, rc=$RC"
  assert_contains "$OUT" "'nobody' is not an account in" "unknown account refusal names the account"
  named_account_run "$fx" --check-account gpro1 gemini-4-neon-medium
  [ "$RC" -eq 1 ] || fail "account whose fresh catalog omits model must refuse, rc=$RC"
  assert_contains "$OUT" "does not list model 'gemini-4-neon-medium'" "model refusal names the model"
  named_account_run "$fx" --check-account gpro1 gemini-3.8-flash-high
  [ "$RC" -eq 0 ] || fail "unreserved account is allowed for flash, rc=$RC $OUT"
  printf 'gpro3\n' > "$fx/unauth"
  named_account_run "$fx" --check-account gpro3 gemini-4-neon-medium
  [ "$RC" -eq 1 ] || fail "unauthenticated account must refuse, rc=$RC"
  assert_contains "$OUT" "not authenticated" "unauthenticated refusal"
  printf '{"user":"gpro2","window_start":1,"reset_at":9999999999,"used_sec":0,"budget_sec":5400,"exhausted":true}\n' > "$fx/state/gpro2.state.json"
  named_account_run "$fx" --check-account gpro2 gemini-4-neon-medium
  [ "$RC" -eq 1 ] || fail "exhausted account must refuse, rc=$RC"
  assert_contains "$OUT" "marked exhausted" "exhausted refusal"
  named_account_run "$fx" --check-account
  [ "$RC" -eq 1 ] || fail "missing account argument must refuse"
  pass "--check-account accepts only a listed, signed-in, catalog-allowed, non-exhausted account and never substitutes another"
}

test_task_data_acl_is_scoped_to_the_selected_account_and_task() {
  local fx="$TMP_ROOT/task_data" home="$TMP_ROOT/task_data/home"
  make_named_account_fixture "$fx"
  mkdir -p "$home/data/scout-1" "$home/data/other-task" "$home/state"
  RC=0
  OUT=$(env PATH="$fx/bin:$PATH" POOL_CONF="$fx/pool.conf" MODELS_CONF="$fx/models.conf" \
    AGY_BIN="$fx/bin/agy" FM_AGY_STATE_DIR="$fx/state" FM_AGY_USAGE_LOG="$fx/usage.jsonl" \
    FM_AGY_PGREP="$fx/bin/fake-pgrep" FM_AGY_USER=gpro3 FM_HOME="$home" FM_TASK_ID=scout-1 \
    "$POOL" --model gemini-4-neon-medium -p hi 2>&1) || RC=$?
  [ "$RC" -eq 0 ] || fail "named-account run failed rc=$RC: $OUT"
  assert_contains "$OUT" "Routing model 'gemini-4-neon-medium' to 'gpro3'" "FM_AGY_USER account is the one used"
  assert_contains "$(cat "$fx/setfacl.log")" "u:gpro3:rwX -m d:u:gpro3:rwX $home/data/scout-1" "scout data dir granted to the selected account"
  assert_not_contains "$(cat "$fx/setfacl.log")" "other-task" "no other task's data is granted"
  assert_not_contains "$(cat "$fx/setfacl.log")" "u:gpro2" "no other pool account is granted"
  pass "the per-task data ACL covers only the selected account and that one task"
}

test_named_unavailable_account_never_falls_back() {
  local fx="$TMP_ROOT/no_fallback"
  make_named_account_fixture "$fx"
  printf 'gpro3\n' > "$fx/unauth"
  named_account_run "$fx" --account gpro3 --model gemini-4-neon-medium -p hi
  [ "$RC" -eq 75 ] || fail "unusable named account must exit 75, got $RC: $OUT"
  assert_not_contains "$OUT" "to 'gpro2'" "must not run on another account"
  pass "a named account that cannot run is refused rather than replaced"
}

test_spawn_gates_are_read_only_and_capacity_aware() {
  local fx="$TMP_ROOT/gates"
  make_named_account_fixture "$fx"
  rm -rf "$fx/state"
  named_account_run "$fx" --check-account gpro2 gemini-4-neon-medium
  [ "$RC" -eq 0 ] || fail "check-account failed rc=$RC $OUT"
  [ ! -e "$fx/state" ] || fail "--check-account must not create the pool state dir"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fx/bin/fake-pgrep"
  named_account_run "$fx" --check-capacity
  [ "$RC" -eq 75 ] || fail "all accounts active and cap 2 must exit 75, got $RC: $OUT"
  assert_contains "$OUT" "cap is 2" "capacity refusal names the cap"
  [ ! -e "$fx/state" ] || fail "--check-capacity must not create the pool state dir"
  # pgrep succeeding for every account means every account is active; a named
  # active account fits, and a raised cap fits.
  named_account_run "$fx" --check-capacity gpro1
  [ "$RC" -eq 0 ] || fail "a named account that is already active fits: $RC $OUT"
  RC=0
  OUT=$(env PATH="$fx/bin:$PATH" POOL_CONF="$fx/pool.conf" MODELS_CONF="$fx/models.conf" FM_AGY_STATE_DIR="$fx/state" \
    FM_AGY_PGREP="$fx/bin/fake-pgrep" FM_AGY_MAX_ACTIVE=9 "$POOL" --check-capacity 2>&1) || RC=$?
  [ "$RC" -eq 0 ] || fail "under a raised cap there is room: $RC $OUT"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fx/bin/fake-pgrep"
  named_account_run "$fx" --check-capacity
  [ "$RC" -eq 0 ] || fail "no active account leaves room: $RC $OUT"
  pass "--check-account and --check-capacity are read-only; capacity exits 75 at the cap"
}

test_gh_config_forwards_only_to_direct_pr_and_local_only_workers() {
  local fx="$TMP_ROOT/gh_scope" home="$TMP_ROOT/gh_scope/home" gh="$TMP_ROOT/gh_scope/xdg/gh"
  make_named_account_fixture "$fx"
  mkdir -p "$home/state" "$gh"
  cat > "$fx/bin/agy" <<EOF2
#!/usr/bin/env bash
if [[ "\${1:-}" == "models" ]]; then
  printf "gemini-4-neon-medium\tGemini 4 Neon (Medium)\n"
  exit 0
fi
if [[ "\${1:-}" == "-p" && "\${2:-}" == "/usage" ]]; then
  printf "Gemini Models\tWeekly Limit Remaining\t90%%\t2026-11-29T00:00:00Z\n"
  printf "Gemini Models\tFive Hour Limit Remaining\t90%%\t2026-11-22T20:00:00Z\n"
  exit 0
fi
printf '%s\n' "\${GH_CONFIG_DIR:-unset}" >> "$fx/gh.log"
exit 0
EOF2
  chmod +x "$fx/bin/agy"
  gh_case() {  # <kind> <mode> <interactive|print>
    : > "$fx/gh.log"
    printf 'kind=%s\nmode=%s\n' "$1" "$2" > "$home/state/t1.meta"
    local flag=-p; [ "$3" = interactive ] && flag=--prompt-interactive
    env PATH="$fx/bin:$PATH" POOL_CONF="$fx/pool.conf" MODELS_CONF="$fx/models.conf" \
      AGY_BIN="$fx/bin/agy" FM_AGY_STATE_DIR="$fx/state" FM_AGY_USAGE_LOG="$fx/usage.jsonl" \
      FM_AGY_PGREP="$fx/bin/fake-pgrep" FM_HOME="$home" FM_TASK_ID=t1 XDG_CONFIG_HOME="$TMP_ROOT/gh_scope/xdg" \
      FM_AGY_PACING_SEC=0 \
      "$POOL" --model gemini-4-neon-medium "$flag" hi >/dev/null 2>&1 </dev/null || true
    cat "$fx/gh.log"
  }
  [ "$(gh_case ship direct-PR interactive)" = "$gh" ] || fail "direct-PR worker must receive gh config"
  [ "$(gh_case ship local-only interactive)" = "$gh" ] || fail "local-only worker must receive gh config"
  [ "$(gh_case ship no-mistakes interactive)" = unset ] || fail "no-mistakes builder must not receive gh config"
  [ "$(gh_case scout '' interactive)" = unset ] || fail "scout must not receive gh config"
  [ "$(gh_case ship direct-PR print)" = unset ] || fail "non-interactive calls (reviewer/fixer) must not receive gh config"
  pass "GH_CONFIG_DIR reaches only interactive direct-PR and local-only ship workers"
}

test_check_account_refuses_unserveable_model_on_recorded_account() {
  # Covers only the --check-account contract that fm-control relaunch and
  # fm-spawn --relaunch call on the recorded account; neither relaunch command
  # is driven here (fm-spawn tmux relaunch refuses an endpoint it cannot prove
  # absent).
  local fx="$TMP_ROOT/relaunch_gate"
  make_named_account_fixture "$fx"
  named_account_run "$fx" --check-account gpro1 gemini-3.8-flash-low
  [ "$RC" -eq 0 ] || fail "the recorded account serves its own model: $RC $OUT"
  named_account_run "$fx" --check-account gpro1 gemini-4-neon-medium
  [ "$RC" -eq 1 ] || fail "switching --model to one the recorded account cannot serve must refuse, got $RC: $OUT"
  assert_contains "$OUT" "does not list model 'gemini-4-neon-medium'" "refusal names the model"
  named_account_run "$fx" --check-account gpro2 gemini-4-neon-medium
  [ "$RC" -eq 0 ] || fail "relaunch --account <other> is the recovery path: $RC $OUT"
  pass "relaunch gate refuses an unserveable model on the recorded account and passes on an explicit other account"
}

# Shared fixture helper for model-discovery, pacing, catalog-gate, and start/end
# quota tests: builds fake id, sudo (honoring $fx/unauth), fake-pgrep, data-driven
# agy (reading $fx/models.<user>|default, $fx/usage.<user>[.after]|default,
# $fx/fail_models, $fx/check_serial), and optional fake date/sleep clock.
make_discovery_fixture() {  # <fx> [--clock <epoch>] <user1> [user2...]
  local fx=$1 clock=""
  shift
  if [[ "${1:-}" == "--clock" ]]; then
    clock=$2
    shift 2
  fi
  rm -rf "$fx"
  mkdir -p "$fx/bin" "$fx/state"
  printf '%s\n' "$@" > "$fx/pool.conf"
  : > "$fx/models.conf"
  : > "$fx/unauth"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fx/bin/id"
  cat > "$fx/bin/sudo" <<EOF
#!/usr/bin/env bash
T=""
while [[ \$# -gt 0 ]]; do case "\$1" in -n|-H) shift ;; -u) T="\$2"; shift 2 ;; *) break ;; esac; done
if [[ "\${1:-}" == "test" ]]; then ! grep -qx "\$T" "$fx/unauth"; exit \$?; fi
SUDO_TARGET_USER="\$T" exec "\$@"
EOF
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fx/bin/fake-pgrep"
  if [[ -n "$clock" ]]; then
    printf '%s\n' "$clock" > "$fx/clock"
    cat > "$fx/bin/date" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "+%s" ]]; then cat "$fx/clock"; exit 0; fi
exec /usr/bin/date "\$@"
EOF
    cat > "$fx/bin/sleep" <<EOF
#!/usr/bin/env bash
sec="\${1:-0}"
if [[ "\$sec" =~ ^[0-9]+$ ]]; then
  cur=\$(cat "$fx/clock")
  echo \$(( cur + sec )) > "$fx/clock"
  printf '%s\n' "\$sec" >> "$fx/sleeps.log"
fi
EOF
  fi
  cat > "$fx/bin/agy" <<EOF
#!/usr/bin/env bash
u="\${SUDO_TARGET_USER:-unknown}"
printf '%s|%s\n' "\$u" "\$*" >> "$fx/live.log"
if [[ "\${1:-}" == "models" || ( "\${1:-}" == "-p" && "\${2:-}" == "/usage" ) ]]; then
  if [[ -f "$fx/check_serial" ]]; then
    [[ -f "$fx/live_inflight" ]] && echo "PARALLEL_LIVE_QUERY" >> "$fx/parallel_error.log"
    : > "$fx/live_inflight"; /usr/bin/sleep 0.15; rm -f "$fx/live_inflight"
  fi
fi
if [[ "\${1:-}" == "models" ]]; then
  printf '%s\n' "\$u" >> "$fx/models_calls.log"
  if [[ -f "$fx/fail_models" ]]; then echo "network error" >&2; exit 1; fi
  if [[ -f "$fx/models.\$u" ]]; then cat "$fx/models.\$u"; else cat "$fx/models.default"; fi
  exit 0
fi
if [[ "\${1:-}" == "-p" && "\${2:-}" == "/usage" ]]; then
  printf '%s\n' "\$u" >> "$fx/usage_calls.log"
  if [[ -f "$fx/started" && -f "$fx/usage.\$u.after" ]]; then cat "$fx/usage.\$u.after"
  elif [[ -f "$fx/started" && -f "$fx/usage.after" ]]; then cat "$fx/usage.after"
  elif [[ -f "$fx/usage.\$u" ]]; then cat "$fx/usage.\$u"
  elif [[ -f "$fx/usage.default" ]]; then cat "$fx/usage.default"
  else
    printf "Gemini Models\tWeekly Limit Remaining\t90%%\t2026-11-29T00:00:00Z\n"
    printf "Gemini Models\tFive Hour Limit Remaining\t90%%\t2026-11-22T20:00:00Z\n"
  fi
  exit 0
fi
printf '%s\n' "\$u" >> "$fx/run_calls.log"
: > "$fx/started"
exit 0
EOF
  chmod +x "$fx/bin/"*
}

discovery_run() {  # <fx> [KEY=VAL ...] -- <pool args...>  -> sets RC and OUT
  local fx=$1
  shift
  local -a extra_env=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    extra_env+=("$1")
    shift
  done
  [[ "${1:-}" == "--" ]] && shift
  RC=0
  OUT=$(env PATH="$fx/bin:$PATH" POOL_CONF="$fx/pool.conf" MODELS_CONF="$fx/models.conf" \
    AGY_BIN="$fx/bin/agy" FM_AGY_STATE_DIR="$fx/state" FM_AGY_USAGE_LOG="$fx/usage.jsonl" \
    FM_AGY_PGREP="$fx/bin/fake-pgrep" FM_AGY_PACING_SEC=0 ${extra_env[@]+"${extra_env[@]}"} \
    "$POOL" "$@" 2>&1) || RC=$?
}

test_catalog_cache_parse_ttl_and_failure_uncertainty() {
  local fx="$TMP_ROOT/catalog_ttl"
  make_discovery_fixture "$fx" gpro1 gpro2
  printf 'Fetching available models...\r\ngemini-4-hydrogen-high\tGemini 4 Hydrogen (High)\r\ngemini-3.8-flash-high\tGemini 3.8 Flash (High)\r\n' > "$fx/models.default"

  # 1. Cold start refreshes only the selected account (gpro1), parsing <id>\t<label> after Fetching line
  discovery_run "$fx" FM_AGY_MODELS_TTL=86400 -- --model gemini-4-hydrogen-high -p hi
  [ "$RC" -eq 0 ] || fail "cold catalog discovery must succeed, got $RC: $OUT"
  [ "$(cat "$fx/models_calls.log")" = "gpro1" ] || fail "must refresh only gpro1, got: $(cat "$fx/models_calls.log")"
  [ ! -e "$fx/state/gpro2.models.json" ] || fail "must not refresh gpro2 when gpro1 succeeds"
  jq -e '(.models | index("gemini-4-hydrogen-high") != null) and (.models | index("Fetching") == null)' "$fx/state/gpro1.models.json" >/dev/null \
    || fail "cached catalog must hold parsed model ids only: $(cat "$fx/state/gpro1.models.json")"

  # 2. Fresh cache reuses without calling agy models again
  : > "$fx/models_calls.log"
  discovery_run "$fx" FM_AGY_MODELS_TTL=86400 -- --model gemini-4-hydrogen-high -p hi
  [ ! -s "$fx/models_calls.log" ] || fail "fresh cache must not invoke agy models: $(cat "$fx/models_calls.log")"

  # 3. Stale cache (old fetched_at) + failed fetch keeps previous cache and reports uncertainty, never support
  printf '{"user":"gpro1","fetched_at":1,"models":["gemini-4-hydrogen-high","gemini-3.8-flash-high"]}\n' > "$fx/state/gpro1.models.json"
  printf '{"user":"gpro2","fetched_at":%s,"models":["gemini-4-hydrogen-high"]}\n' "$(date +%s)" > "$fx/state/gpro2.models.json"
  : > "$fx/models_calls.log"
  : > "$fx/fail_models"
  discovery_run "$fx" FM_AGY_MODELS_TTL=3600 -- --model gemini-4-hydrogen-high -p hi
  [ "$RC" -eq 0 ] || fail "selection must fall back to fresh gpro2 when gpro1 fetch fails, got $RC: $OUT"
  assert_contains "$OUT" "uncertain" "failed fetch must be reported as uncertainty"
  assert_contains "$OUT" "Routing model 'gemini-4-hydrogen-high' to 'gpro2'" "failed fetch on gpro1 must not be treated as support"
  [ "$(jq -r '.fetched_at' "$fx/state/gpro1.models.json")" = "1" ] || fail "failed fetch must preserve previous gpro1 cache"

  pass "per-account catalog cache parses models, honors TTL for one account, and keeps prior cache as uncertainty on failure"
}

test_selection_sticky_quota_order_and_single_query() {
  local fx="$TMP_ROOT/selection_order" now_ts u
  make_discovery_fixture "$fx" gpro1 gpro2 gpro3 gpro4
  printf 'gemini-4-hydrogen-high\tGemini 4 Hydrogen (High)\ngpt-oss-120b-medium\tGPT-OSS 120B (Medium)\n' > "$fx/models.default"
  printf 'Gemini Models\tWeekly Limit Remaining\t10%%\t2026-12-05T00:00:00Z\nGemini Models\tFive Hour Limit Remaining\t10%%\t2026-12-05T00:00:00Z\nClaude and GPT models\tWeekly Limit Remaining\t95%%\t2026-12-05T00:00:00Z\nClaude and GPT models\tFive Hour Limit Remaining\t90%%\t2026-12-05T00:00:00Z\n' > "$fx/usage.gpro2"
  printf 'Gemini Models\tWeekly Limit Remaining\t92%%\t2026-12-05T00:00:00Z\nGemini Models\tFive Hour Limit Remaining\t88%%\t2026-12-05T00:00:00Z\nClaude and GPT models\tWeekly Limit Remaining\t95%%\t2026-12-05T00:00:00Z\nClaude and GPT models\tFive Hour Limit Remaining\t90%%\t2026-12-05T00:00:00Z\n' > "$fx/usage.gpro3"
  printf 'Gemini Models\tWeekly Limit Remaining\t60%%\t2026-12-05T00:00:00Z\nGemini Models\tFive Hour Limit Remaining\t60%%\t2026-12-05T00:00:00Z\nClaude and GPT models\tWeekly Limit Remaining\t95%%\t2026-12-05T00:00:00Z\nClaude and GPT models\tFive Hour Limit Remaining\t90%%\t2026-12-05T00:00:00Z\n' > "$fx/usage.default"

  now_ts=$(date +%s)
  for u in gpro1 gpro2 gpro3 gpro4; do
    printf '{"user":"%s","fetched_at":%s,"models":["gemini-4-hydrogen-high","gpt-oss-120b-medium"]}\n' "$u" "$now_ts" > "$fx/state/${u}.models.json"
  done
  # Sticky is gpro2 (live check will return 10% <= floor); gpro1=40%, gpro3=85%, gpro4=5% (below floor until future reset)
  printf 'gpro2\n' > "$fx/state/last-active"
  printf '{"user":"gpro1","window_start":1,"reset_at":0,"used_sec":0,"budget_sec":5400,"exhausted":false,"quota":{"Gemini Models":{"min_pct":40,"reset_at":0}}}\n' > "$fx/state/gpro1.state.json"
  printf '{"user":"gpro3","window_start":1,"reset_at":0,"used_sec":0,"budget_sec":5400,"exhausted":false,"quota":{"Gemini Models":{"min_pct":85,"reset_at":0}}}\n' > "$fx/state/gpro3.state.json"
  printf '{"user":"gpro4","window_start":1,"reset_at":9999999999,"used_sec":0,"budget_sec":5400,"exhausted":true,"quota":{"Gemini Models":{"min_pct":5,"reset_at":9999999999}}}\n' > "$fx/state/gpro4.state.json"

  discovery_run "$fx" -- --model gemini-4-hydrogen-high -p hi
  [ "$RC" -eq 0 ] || fail "selection must succeed on gpro3, got $RC: $OUT"
  assert_contains "$OUT" "Routing model 'gemini-4-hydrogen-high' to 'gpro3'" "must route to highest remaining gpro3 after sticky gpro2 fails"
  # usage_calls.log has start checks (gpro2, gpro3) and end check (gpro3)
  [ "$(head -n 2 "$fx/usage_calls.log")" = $'gpro2\ngpro3' ] || fail "must check sticky gpro2 first then highest-quota gpro3 (skipping gpro4, never checking gpro1 or gpro2 twice): $(cat "$fx/usage_calls.log")"

  # gpt-* model routes using "Claude and GPT models" group even when Gemini Models is low
  : > "$fx/usage_calls.log"
  printf 'gpro2\n' > "$fx/state/last-active"
  printf '{"user":"gpro2","window_start":1,"reset_at":0,"used_sec":0,"budget_sec":5400,"exhausted":false,"quota":{"Gemini Models":{"min_pct":10,"reset_at":9999999999}}}\n' > "$fx/state/gpro2.state.json"
  discovery_run "$fx" -- --model gpt-oss-120b-medium -p hi
  [ "$RC" -eq 0 ] || fail "gpt model must use Claude and GPT models group quota on sticky gpro2, got $RC: $OUT"
  assert_contains "$OUT" "Routing model 'gpt-oss-120b-medium' to 'gpro2'" "gpt model stays on gpro2 via Claude and GPT models group"

  pass "selection tries sticky first, orders remaining by last quota descending, skips below-floor until reset, and maps model group"
}

test_reservation_from_catalog_and_hydrogen_unrestricted() {
  local fx="$TMP_ROOT/reservation_catalog"
  # Put reserved piyushjiit FIRST in pool.conf AND put stale *hydrogen* restriction in models.conf
  make_discovery_fixture "$fx" piyushjiit gpro1
  printf '*hydrogen* piyushjiit\n*neon* piyushjiit\n' > "$fx/models.conf"
  printf 'gemini-4-neon-medium\tGemini 4 Neon (Medium)\ngemini-4-hydrogen-high\tGemini 4 Hydrogen (High)\n' > "$fx/models.piyushjiit"
  printf 'gemini-4-hydrogen-high\tGemini 4 Hydrogen (High)\ngemini-3.8-flash-high\tGemini 3.8 Flash (High)\n' > "$fx/models.default"

  # 1. Even with sticky=piyushjiit and stale models.conf *hydrogen* piyushjiit, Hydrogen prefers non-reserved gpro1!
  printf 'piyushjiit\n' > "$fx/state/last-active"
  discovery_run "$fx" -- --model gemini-4-hydrogen-high -p hi
  [ "$RC" -eq 0 ] || fail "Hydrogen must prefer non-reserved gpro1, got $RC: $OUT"
  [ "$(cat "$fx/run_calls.log")" = "gpro1" ] || fail "Hydrogen must route to non-reserved gpro1 despite stale models.conf and sticky piyushjiit: $(cat "$fx/run_calls.log")"

  # 2. Neon routes ONLY to catalog-capable piyushjiit
  : > "$fx/run_calls.log"
  discovery_run "$fx" -- --model gemini-4-neon-medium -p hi
  [ "$RC" -eq 0 ] || fail "Neon must route to piyushjiit, got $RC: $OUT"
  [ "$(cat "$fx/run_calls.log")" = "piyushjiit" ] || fail "Neon must run on piyushjiit: $(cat "$fx/run_calls.log")"

  pass "Neon-capable catalog reserves account, Hydrogen/Flash ignore stale gpro-models.conf and prefer non-reserved accounts"
}

test_live_query_pacing_and_lock() {
  local fx="$TMP_ROOT/pacing_lock"
  make_discovery_fixture "$fx" --clock 1000 gpro1 gpro2
  : > "$fx/check_serial"
  printf 'gemini-3.8-flash-high\tGemini 3.8 Flash (High)\n' > "$fx/models.default"
  printf 'Gemini Models\tWeekly Limit Remaining\t10%%\t2026-12-05T00:00:00Z\nGemini Models\tFive Hour Limit Remaining\t10%%\t2026-12-05T00:00:00Z\n' > "$fx/usage.gpro1"

  # 1. Cold start on gpro1 (models + /usage -> same account, NO gap!) -> gpro1 10% skip -> gpro2 (different account -> 60s gap!) -> gpro2 /usage (same account -> NO gap!) -> end /usage (same account gpro2 -> NO gap!)
  discovery_run "$fx" FM_AGY_PACING_SEC=60 FM_AGY_LIVE_TIMEOUT=0 -- --model gemini-3.8-flash-high -p hi
  [ "$RC" -eq 0 ] || fail "paced selection must succeed on gpro2, got $RC: $OUT"
  [ "$(cat "$fx/sleeps.log")" = "60" ] || fail "expected exactly one 60s sleep between gpro1 and gpro2 only, got: $(cat "$fx/sleeps.log")"

  # 2. Two parallel invocations serialize under live-query.lock without parallel live queries
  : > "$fx/parallel_error.log"
  discovery_run "$fx" FM_AGY_PACING_SEC=60 FM_AGY_LIVE_TIMEOUT=0 -- --model gemini-3.8-flash-high -p hi &
  local p1=$!
  discovery_run "$fx" FM_AGY_PACING_SEC=60 FM_AGY_LIVE_TIMEOUT=0 -- --model gemini-3.8-flash-high -p hi &
  local p2=$!
  wait "$p1" "$p2"
  [ ! -s "$fx/parallel_error.log" ] || fail "live queries must never run in parallel: $(cat "$fx/parallel_error.log")"

  pass "machine-wide lock serializes live queries and paces different accounts without gapping same-account queries"
}

test_check_account_and_spawn_probe_cache_gates() {
  local fx="$TMP_ROOT/check_gates_cache" now_ts
  make_discovery_fixture "$fx" gpro1 gpro2 gpro3
  rm -rf "$fx/state"

  # 1. Missing catalog -> --check-account allows with notice and stays read-only
  discovery_run "$fx" -- --check-account gpro1 gemini-4-neon-medium
  [ "$RC" -eq 0 ] || fail "missing catalog must allow with notice, got $RC: $OUT"
  assert_contains "$OUT" "unknown (missing)" "missing catalog notice"
  [ ! -e "$fx/state" ] || fail "--check-account must stay read-only"
  [ ! -e "$fx/live.log" ] || fail "--check-account must never query live"

  # 2. Stale catalog -> --check-account and --check-model allow with notice
  mkdir -p "$fx/state"
  printf '{"user":"gpro1","fetched_at":1,"models":["gemini-3.8-flash-high"]}\n' > "$fx/state/gpro1.models.json"
  discovery_run "$fx" -- --check-account gpro1 gemini-4-neon-medium
  [ "$RC" -eq 0 ] || fail "stale catalog must allow with notice, got $RC: $OUT"
  assert_contains "$OUT" "unknown (stale)" "stale catalog notice"
  discovery_run "$fx" -- --check-model gemini-4-neon-medium gpro1
  [ "$RC" -eq 0 ] || fail "stale catalog --check-model must allow with notice, got $RC: $OUT"
  [ ! -e "$fx/live.log" ] || fail "--check-model must never query live"

  # 3. Fresh catalog omitting model refuses; fresh catalog listing model passes
  now_ts=$(date +%s)
  printf '{"user":"gpro1","fetched_at":%s,"models":["gemini-3.8-flash-high"]}\n' "$now_ts" > "$fx/state/gpro1.models.json"
  printf '{"user":"gpro2","fetched_at":%s,"models":["gemini-3.8-flash-high"]}\n' "$now_ts" > "$fx/state/gpro2.models.json"
  printf '{"user":"gpro3","fetched_at":%s,"models":["gemini-3.8-flash-high"]}\n' "$now_ts" > "$fx/state/gpro3.models.json"
  discovery_run "$fx" -- --check-model gemini-4-neon-medium
  [ "$RC" -eq 1 ] || fail "all-fresh pool omitting model must refuse --check-model, got $RC: $OUT"
  printf '{"user":"gpro2","fetched_at":%s,"models":["gemini-3.8-flash-high","gemini-4-neon-medium"]}\n' "$now_ts" > "$fx/state/gpro2.models.json"
  discovery_run "$fx" -- --check-model gemini-4-neon-medium
  [ "$RC" -eq 0 ] || fail "pool with a fresh catalog listing model must pass --check-model, got $RC: $OUT"

  pass "--check-account and --check-model enforce fresh catalogs read-only and allow unknown catalogs with a notice"
}

test_start_and_end_quota_records() {
  local fx="$TMP_ROOT/start_end_records"
  make_discovery_fixture "$fx" gpro1
  printf 'gemini-4-hydrogen-high\tGemini 4 Hydrogen (High)\n' > "$fx/models.default"
  printf 'Gemini Models\tWeekly Limit Remaining\t80%%\t2026-12-01T00:00:00Z\nGemini Models\tFive Hour Limit Remaining\t95%%\t2026-11-26T05:00:00Z\n' > "$fx/usage.default"
  printf 'Gemini Models\tWeekly Limit Remaining\t78%%\t2026-12-01T00:00:00Z\nGemini Models\tFive Hour Limit Remaining\t85%%\t2026-11-26T05:00:00Z\n' > "$fx/usage.after"

  discovery_run "$fx" FM_TASK_ID="task-fqd-1" -- --model gemini-4-hydrogen-high -p hi
  [ "$RC" -eq 0 ] || fail "run must exit 0, got $RC"

  local start_rec end_rec sum_rec
  start_rec=$(jq -sc '[.[] | select(.event == "usage_check" and .decision == "start")] | last' "$fx/usage.jsonl")
  end_rec=$(jq -sc '[.[] | select(.event == "quota_end")] | last' "$fx/usage.jsonl")
  sum_rec=$(jq -sc '[.[] | select(has("duration_sec"))] | last' "$fx/usage.jsonl")

  [ "$(jq -r '.task + "|" + .user + "|" + .model + "|" + .group + "|" + (.weekly_pct|tostring) + "|" + .weekly_reset + "|" + (.five_hour_pct|tostring) + "|" + .five_hour_reset' <<<"$start_rec")" = "task-fqd-1|gpro1|gemini-4-hydrogen-high|Gemini Models|80|2026-12-01T00:00:00Z|95|2026-11-26T05:00:00Z" ] \
    || fail "start usage_check record mismatch: $start_rec"
  [ "$(jq -r '.task + "|" + .user + "|" + .model + "|" + .group + "|" + (.weekly_pct|tostring) + "|" + .weekly_reset + "|" + (.five_hour_pct|tostring) + "|" + .five_hour_reset' <<<"$end_rec")" = "task-fqd-1|gpro1|gemini-4-hydrogen-high|Gemini Models|78|2026-12-01T00:00:00Z|85|2026-11-26T05:00:00Z" ] \
    || fail "quota_end record mismatch: $end_rec"
  [ "$(jq -r '.task + "|" + .user + "|" + (.exit_code|tostring)' <<<"$sum_rec")" = "task-fqd-1|gpro1|0" ] \
    || fail "backward-compatible run summary mismatch: $sum_rec"

  pass "usage log records both group windows at start (usage_check) and end (quota_end) while keeping run summary"
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
  test_cap_reuse_follows_model_order \
  test_active_account_reuse_allows_uncertain_catalog \
  test_usage_follows_active_cap \
  test_forged_conversation_record_is_not_trusted \
  test_check_account_validates_a_named_account \
  test_task_data_acl_is_scoped_to_the_selected_account_and_task \
  test_named_unavailable_account_never_falls_back \
  test_spawn_gates_are_read_only_and_capacity_aware \
  test_gh_config_forwards_only_to_direct_pr_and_local_only_workers \
  test_check_account_refuses_unserveable_model_on_recorded_account \
  test_catalog_cache_parse_ttl_and_failure_uncertainty \
  test_selection_sticky_quota_order_and_single_query \
  test_reservation_from_catalog_and_hydrogen_unrestricted \
  test_live_query_pacing_and_lock \
  test_check_account_and_spawn_probe_cache_gates \
  test_start_and_end_quota_records
