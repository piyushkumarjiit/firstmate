#!/usr/bin/env bash
# Scenario: sticky account first, quota-ordered fallback, and a live start
# reading printed + logged on every selection path (including an already-active
# explicit account and the at-cap active branch).
set -uo pipefail
ROOT=~/.no-mistakes/worktrees/406d2d249c60/01M8C175QRFR8PN3KCPEG4F3C7
LAUNCHER=$ROOT/bin/agy-pool/agy
FIX=$1
OUT=$2
mkdir -p "$OUT"
. /tmp/fm-live-scen/fixture.sh "$FIX" >/dev/null

# config order deliberately puts the sticky account last
printf 'acct_c\nacct_a\nacct_b\n' > "$FIX/pool.conf"
: > "$FIX/legacy-models.conf"
now=$(date +%s)

step() { printf '\n### %s\n' "$*"; }
set_reading() {  # <acct> <pct>
  jq -c --arg u "$1" --argjson pct "$2" --argjson now "$now" \
    '{user:$u, window_start:0, reset_at:0, used_sec:0, budget_sec:5400, exhausted:false,
      quota:{"Gemini Models":{min_pct:$pct, reset:"2027-12-03T13:51:31Z", reset_at:1795000000, weekly_pct:$pct, weekly_reset:"2027-12-03T13:51:31Z", five_hour_pct:$pct, five_hour_reset:"2027-11-26T18:51:31Z", checked_at:$now}}}' \
    > "$FIX/state/$1.state.json"
}

step "seed saved quota readings for acct_a (85) and acct_c (45) through the real --usage path"
"$FIX/run-pool" --usage acct_a 2>&1 | sed 's/^/  /'
"$FIX/run-pool" --usage acct_c 2>&1 | sed 's/^/  /'
: > "$FIX/calls.log"

step "make acct_b the last-active account by running one task explicitly on it"
timeout 120 "$FIX/run-pool" --user acct_b --model gemini-3.8-flash-high -p hello 2>&1 | sed 's/^/  /'
echo "  last-active=$(cat "$FIX/state/last-active")"

step "A. automatic Flash task: sticky acct_b must win over acct_a's higher saved reading"
: > "$FIX/calls.log"
timeout 120 "$FIX/run-pool" --model gemini-3.8-flash-high -p hello 2>&1 | sed 's/^/  /'
A_calls=$(cat "$FIX/calls.log")

step "B. acct_b's cached catalog no longer lists Flash: fallback must follow last saved reading (a 85 before c 45), not config order"
jq -nc --argjson ts "$now" '{user:"acct_b", fetched_at:$ts, models:["gemini-4-hydrogen-high"]}' \
  > "$FIX/state/acct_b.models.json"
: > "$FIX/calls.log"
timeout 120 "$FIX/run-pool" --model gemini-3.8-flash-high -p hello 2>&1 | sed 's/^/  /'
B_calls=$(cat "$FIX/calls.log")

step "C. at the active cap (acct_a and acct_c active, sticky not active): reuse ordered by saved reading, live reading printed and logged"
write_usage acct_a 62
write_usage acct_c 77
printf 'acct_a\nacct_c\n' > "$FIX/active"
: > "$FIX/calls.log"
timeout 120 "$FIX/run-pool" --model gemini-3.8-flash-high -p hello 2>&1 | sed 's/^/  /'
C_calls=$(cat "$FIX/calls.log")

step "D. explicit already-active account: one live /usage of that same account, printed and logged"
write_usage acct_c 48
: > "$FIX/calls.log"
timeout 120 env FM_AGY_USER=acct_c "$FIX/run-pool" --model gemini-3.8-flash-high -p hello 2>&1 | sed 's/^/  /'
D_calls=$(cat "$FIX/calls.log")
: > "$FIX/active"

step "usage log start/end records"
jq -c 'select(.event != null) | {ts, user, event, decision, gemini_min_pct}' "$FIX/usage.jsonl"

{
  echo "== calls (epoch_ms account argv) =="
  echo "A sticky:";      printf '%s\n' "$A_calls"
  echo "B fallback:";    printf '%s\n' "$B_calls"
  echo "C at-cap:";      printf '%s\n' "$C_calls"
  echo "D explicit:";    printf '%s\n' "$D_calls"
  echo
  echo "== usage log =="
  cat "$FIX/usage.jsonl"
  echo
  echo "== saved readings at end =="
  for f in "$FIX"/state/*.state.json; do echo "-- ${f##*/}"; jq -c '{user, exhausted, quota}' "$f"; done
} > "$OUT/scenario4-transcript.txt" 2>&1

# --- assertions; the oracle is the stub's per-account catalog/reading values ---
fail=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }

check "A sticky acct_b took the task without querying a higher-quota account" \
  "grep -q 'acct_b	--model gemini-3.8-flash-high' <<<\"\$A_calls\" && ! grep -q 'acct_a' <<<\"\$A_calls\" && ! grep -q 'acct_c' <<<\"\$A_calls\""
check "B fallback chose acct_a (saved 85) and never queried acct_c (saved 45)" \
  "grep -q 'acct_a	models' <<<\"\$B_calls\" && grep -q 'acct_a	--model' <<<\"\$B_calls\" && ! grep -q 'acct_c' <<<\"\$B_calls\""
check "C at-cap reuse chose acct_a by saved reading with one live /usage of acct_a only" \
  "grep -q 'acct_a	-p /usage' <<<\"\$C_calls\" && grep -q 'acct_a	--model' <<<\"\$C_calls\" && ! grep -q 'acct_c	-p /usage' <<<\"\$C_calls\""
check "D explicit active acct_c took one live /usage of acct_c only" \
  "grep -q 'acct_c	-p /usage' <<<\"\$D_calls\" && ! grep -q 'acct_a	-p /usage' <<<\"\$D_calls\""
check "C start reading logged at the live 62% (not the saved 85, not the 100 estimate)" \
  "jq -se '[.[] | select(.event==\"usage_check\" and .user==\"acct_a\" and .decision==\"start\" and .gemini_min_pct==62)] | length >= 1' \"$FIX/usage.jsonl\" >/dev/null"
check "D start reading logged at the live 48% for the already-active explicit account" \
  "jq -se '[.[] | select(.event==\"usage_check\" and .user==\"acct_c\" and .decision==\"start\" and .gemini_min_pct==48)] | length >= 1' \"$FIX/usage.jsonl\" >/dev/null"
check "every selection recorded one quota_end reading for the account it ran" \
  "jq -se '[.[] | select(.event==\"quota_end\")] | length >= 5' \"$FIX/usage.jsonl\" >/dev/null"
[ "$fail" -eq 0 ] && echo "SCENARIO4 PASS" || echo "SCENARIO4 FAIL"
exit "$fail"
