#!/usr/bin/env bash
# Scenario: real-account model discovery drives the launch decision (no
# hard-coded model map, legacy gpro-models.conf ignored), the read-only spawn
# gates report the cached catalog, and a fresh cached catalog is reused while a
# stale one is refreshed for that account.
set -uo pipefail
ROOT=~/.no-mistakes/worktrees/406d2d249c60/01M8C175QRFR8PN3KCPEG4F3C7
LAUNCHER=$ROOT/bin/agy-pool/agy
LAB=$1
OUT=$2
mkdir -p "$OUT" "$LAB/state" "$LAB/home"
printf 'agentic\n' > "$LAB/pool.conf"
: > "$LAB/legacy-models.conf"

POOL_ENV=(env POOL_CONF="$LAB/pool.conf" MODELS_CONF="$LAB/legacy-models.conf"
  FM_AGY_STATE_DIR="$LAB/state" FM_AGY_USAGE_LOG="$LAB/usage.jsonl"
  FM_AGY_PACING_SEC=0 FM_HOME="$LAB/home" HOME="$LAB/home"
  FM_TASK_ID=live-gate)

step() { printf '\n### %s\n' "$*"; }

step "1. read-only gates with no catalog yet: allow with an unknown notice, create no state"
before=$(ls -A "$LAB/state")
set +e
"${POOL_ENV[@]}" "$LAUNCHER" --check-model gemini-4-neon-high > "$OUT/check-model-unknown.txt" 2>&1
rm_unknown=$?
"${POOL_ENV[@]}" "$LAUNCHER" --check-account agentic gemini-4-neon-high > "$OUT/check-account-unknown.txt" 2>&1
ra_unknown=$?
set -e
after=$(ls -A "$LAB/state")
cat "$OUT/check-model-unknown.txt" "$OUT/check-account-unknown.txt" | sed 's/^/  /'
echo "  exits: check-model=$rm_unknown check-account=$ra_unknown state: [$before] -> [$after]"

step "2. real launch on a Hydrogen model discovers this account's catalog from live 'agy models'"
timeout 180 "${POOL_ENV[@]}" "$LAUNCHER" --model gemini-4-hydrogen-low -p "Reply with exactly: FM_HYDRO_OK" 2> "$LAB/route-hydrogen.txt"
hydro_rc=$?
sed 's/^/  /' "$LAB/route-hydrogen.txt"
echo "  catalog: $(jq -c '.models' "$LAB/state/agentic.models.json")"
fetched1=$(jq -r '.fetched_at' "$LAB/state/agentic.models.json")

step "3. freshly cached catalog: the read-only gates refuse a model this account does not have"
set +e
"${POOL_ENV[@]}" "$LAUNCHER" --check-model gemini-4-neon-high > "$OUT/check-model-fresh.txt" 2>&1
rm_fresh=$?
"${POOL_ENV[@]}" "$LAUNCHER" --check-account agentic gemini-4-neon-high > "$OUT/check-account-fresh.txt" 2>&1
ra_fresh=$?
"${POOL_ENV[@]}" "$LAUNCHER" --check-model gemini-4-hydrogen-low > "$OUT/check-model-supported.txt" 2>&1
rm_ok=$?
"${POOL_ENV[@]}" "$LAUNCHER" --check-account agentic gemini-4-hydrogen-low > "$OUT/check-account-supported.txt" 2>&1
ra_ok=$?
set -e
cat "$OUT/check-model-fresh.txt" "$OUT/check-account-fresh.txt" "$OUT/check-model-supported.txt" "$OUT/check-account-supported.txt" | sed 's/^/  /'
echo "  exits: unsupported model=$rm_fresh/$ra_fresh supported model=$rm_ok/$ra_ok"

step "4. legacy gpro-models.conf naming this account for Neon does not make a Neon launch possible"
printf '*neon* agentic\n*hydrogen* agentic\n' > "$LAB/legacy-models.conf"
set +e
timeout 120 "${POOL_ENV[@]}" "$LAUNCHER" --model gemini-4-neon-high -p "Reply with exactly: FM_NEON_OK" \
  > "$OUT/neon-launch-stdout.txt" 2> "$OUT/neon-launch-stderr.txt"
neon_rc=$?
set -e
sed 's/^/  /' "$OUT/neon-launch-stderr.txt"
echo "  exit=$neon_rc stdout=[$(cat "$OUT/neon-launch-stdout.txt")]"

step "5. a fresh catalog is reused: second launch does not re-fetch models"
lastq1=$(cat "$LAB/state/last-live-query")
timeout 180 "${POOL_ENV[@]}" "$LAUNCHER" --model gemini-4-hydrogen-low -p "Reply with exactly: FM_HYDRO_OK" \
  > "$OUT/reuse-stdout.txt" 2> "$OUT/reuse-stderr.txt"
reuse_rc=$?
sed 's/^/  /' "$OUT/reuse-stderr.txt"
fetched2=$(jq -r '.fetched_at' "$LAB/state/agentic.models.json")
echo "  fetched_at before=$fetched1 after=$fetched2 (unchanged means no live models fetch)"

step "6. stale catalog (TTL=1s) is refreshed for this account"
sleep 2
lastq2=$(cat "$LAB/state/last-live-query")
FM_AGY_MODELS_TTL=1 timeout 180 "${POOL_ENV[@]}" "$LAUNCHER" --model gemini-4-hydrogen-low -p "Reply with exactly: FM_HYDRO_OK" \
  > "$OUT/stale-stdout.txt" 2> "$OUT/stale-stderr.txt"
stale_rc=$?
fetched3=$(jq -r '.fetched_at' "$LAB/state/agentic.models.json")
echo "  fetched_at after stale run=$fetched3 (changed means the stale catalog was refreshed)"

step "usage log (start and end readings for every task)"
jq -c '{ts, user, model, event, decision, gemini_min_pct}' "$LAB/usage.jsonl" | sed 's/^/  /'

{
  echo "== check gates =="
  echo "-- unknown catalog, unsupported model (exit $rm_unknown / $ra_unknown)"; cat "$OUT/check-model-unknown.txt" "$OUT/check-account-unknown.txt"
  echo "-- fresh catalog, unsupported model (exit $rm_fresh / $ra_fresh)"; cat "$OUT/check-model-fresh.txt" "$OUT/check-account-fresh.txt"
  echo "-- fresh catalog, supported model (exit $rm_ok / $ra_ok)"; cat "$OUT/check-model-supported.txt" "$OUT/check-account-supported.txt"
  echo
  echo "== live launches =="
  echo "-- hydrogen catalog discovery (exit $hydro_rc)"; cat "$LAB/route-hydrogen.txt"
  echo "-- neon request with legacy map (exit $neon_rc)"; cat "$OUT/neon-launch-stderr.txt"
  echo "-- fresh-catalog reuse (exit $reuse_rc)"; cat "$OUT/reuse-stderr.txt"
  echo "-- stale-catalog refresh (exit $stale_rc)"; cat "$OUT/stale-stderr.txt"
  echo
  echo "== state =="
  jq . "$LAB/state/agentic.models.json"
  echo
  echo "== usage log =="
  cat "$LAB/usage.jsonl"
} > "$OUT/scenario23-transcript.txt" 2>&1

fail=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }

check "unknown catalog gates allow with a notice and leave state untouched" \
  "[ \"$rm_unknown\" -eq 0 ] && [ \"$ra_unknown\" -eq 0 ] && grep -q 'unknown' \"$OUT/check-model-unknown.txt\" && [ \"$before\" = \"$after\" ]"
check "real Hydrogen launch succeeded and cached the account's discovered catalog" \
  "[ \"$hydro_rc\" -eq 0 ] && jq -e '.models | index(\"gemini-4-hydrogen-low\") != null' \"$LAB/state/agentic.models.json\" >/dev/null"
check "fresh catalog gate refuses a model the account's catalog lacks" \
  "[ \"$rm_fresh\" -eq 1 ] && [ \"$ra_fresh\" -eq 1 ] && grep -q 'not listed' \"$OUT/check-model-fresh.txt\" && grep -q 'not list model' \"$OUT/check-account-fresh.txt\""
check "fresh catalog gate allows a model the account's catalog lists" \
  "[ \"$rm_ok\" -eq 0 ] && [ \"$ra_ok\" -eq 0 ] && grep -qx 'agentic' \"$OUT/check-account-supported.txt\""
check "Neon launch refused (exit 75, agy never answered) even though legacy map allows the account" \
  "[ \"$neon_rc\" -eq 75 ] && [ -s \"$OUT/neon-launch-stderr.txt\" ] && ! grep -qi 'FM_NEON_OK' \"$OUT/neon-launch-stdout.txt\""
check "fresh catalog reused without a new models fetch" \
  "[ \"$reuse_rc\" -eq 0 ] && [ \"$fetched1\" = \"$fetched2\" ]"
check "stale catalog refreshed for the account" \
  "[ \"$stale_rc\" -eq 0 ] && [ \"$fetched1\" != \"$fetched3\" ]"
check "usage log has a start reading and an end reading for every launched task" \
  "jq -se '([.[] | select(.event==\"usage_check\" and .decision==\"start\")] | length) >= 3 and ([.[] | select(.event==\"quota_end\")] | length) >= 3' \"$LAB/usage.jsonl\" >/dev/null"
[ "$fail" -eq 0 ] && echo "SCENARIO23 PASS" || echo "SCENARIO23 FAIL"
exit "$fail"
