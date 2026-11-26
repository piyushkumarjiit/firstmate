#!/usr/bin/env bash
# Scenario: Neon-capable accounts are discovered from their own catalogs and
# reserved - Flash/Hydrogen work prefers a non-Neon account (even when the Neon
# account is listed first and has a higher saved reading, and even when the
# legacy gpro-models.conf maps the model to the Neon account), while Neon work
# uses the Neon account.
set -uo pipefail
ROOT=~/.no-mistakes/worktrees/406d2d249c60/01M8C175QRFR8PN3KCPEG4F3C7
LAUNCHER=$ROOT/bin/agy-pool/agy
FIX=$1
OUT=$2
mkdir -p "$OUT"
. /tmp/fm-live-scen/fixture.sh "$FIX" >/dev/null

# Neon account first, plus a stale legacy map that would have forced Neon work
# onto the non-Neon account.
printf 'neon1\nplain1\n' > "$FIX/pool.conf"
printf '*neon* plain1\n*hydrogen* plain1\n' > "$FIX/legacy-models.conf"

step() { printf '\n### %s\n' "$*"; }

step "seed saved readings: neon account 95, plain account 50"
"$FIX/run-pool" --usage neon1 2>&1 | sed 's/^/  /'
"$FIX/run-pool" --usage plain1 2>&1 | sed 's/^/  /'
: > "$FIX/calls.log"

step "Flash task: non-Neon plain1 must win over the Neon account's higher reading"
timeout 120 "$FIX/run-pool" --model gemini-3.8-flash-high -p hello 2>&1 | sed 's/^/  /'
flash_calls=$(cat "$FIX/calls.log")

step "Hydrogen task: still plain1, Neon budget untouched"
: > "$FIX/calls.log"
timeout 120 "$FIX/run-pool" --model gemini-4-hydrogen-high -p hello 2>&1 | sed 's/^/  /'
hydrogen_calls=$(cat "$FIX/calls.log")

step "plain1 exhausted: Flash may spill onto the Neon account rather than fail"
printf '{"user":"plain1","window_start":0,"reset_at":9999999999,"used_sec":100,"budget_sec":100,"exhausted":true}\n' \
  > "$FIX/state/plain1.state.json"
: > "$FIX/calls.log"
timeout 120 "$FIX/run-pool" --model gemini-3.8-flash-high -p hello 2>&1 | sed 's/^/  /'
spill_calls=$(cat "$FIX/calls.log")

step "Neon task: only the Neon-capable account can serve it (plain1 catalog lacks Neon, legacy map ignored)"
rm -f "$FIX/state/plain1.state.json"
: > "$FIX/calls.log"
timeout 120 "$FIX/run-pool" --model gemini-4-neon-high -p hello 2>&1 | sed 's/^/  /'
neon_calls=$(cat "$FIX/calls.log")

step "status view"
"$FIX/run-pool" --status 2>&1 | sed 's/^/  /'

{
  echo "== catalogs (per-account discovery input) =="
  for f in "$FIX"/catalog-*.txt; do echo "-- ${f##*/}"; cat "$f"; done
  echo "== live calls =="
  echo "Flash:";     printf '%s\n' "$flash_calls"
  echo "Hydrogen:";  printf '%s\n' "$hydrogen_calls"
  echo "Flash spill:"; printf '%s\n' "$spill_calls"
  echo "Neon:";      printf '%s\n' "$neon_calls"
  echo
  echo "== usage log =="
  cat "$FIX/usage.jsonl"
} > "$OUT/scenario5-transcript.txt" 2>&1

fail=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }

check "Flash ran on plain1 with no Neon quota reading or Neon-side run" \
  "grep -q 'plain1	--model gemini-3.8-flash-high' <<<\"\$flash_calls\" && ! grep -q 'neon1	-p /usage' <<<\"\$flash_calls\" && ! grep -q 'neon1	--model' <<<\"\$flash_calls\""
check "Hydrogen ran on plain1 with no Neon quota reading or Neon-side run" \
  "grep -q 'plain1	--model gemini-4-hydrogen-high' <<<\"\$hydrogen_calls\" && ! grep -q 'neon1	-p /usage' <<<\"\$hydrogen_calls\" && ! grep -q 'neon1	--model' <<<\"\$hydrogen_calls\""
check "exhausted plain1 spills Flash onto neon1" \
  "grep -q 'neon1	--model gemini-3.8-flash-high' <<<\"\$spill_calls\""
check "Neon model ran on neon1, not the account the legacy map named" \
  "grep -q 'neon1	--model gemini-4-neon-high' <<<\"\$neon_calls\" && ! grep -q 'plain1	--model gemini-4-neon-high' <<<\"\$neon_calls\""
check "neon1 catalog shows the Neon-capable tier in the status view" \
  "grep -q 'neon1.*reserved (neon)' <<<\"\$(\"\$FIX/run-pool\" --status 2>/dev/null)\""
[ "$fail" -eq 0 ] && echo "SCENARIO5 PASS" || echo "SCENARIO5 FAIL"
exit "$fail"
