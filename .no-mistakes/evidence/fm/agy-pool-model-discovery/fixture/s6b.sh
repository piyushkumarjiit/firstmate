#!/usr/bin/env bash
set -uo pipefail
. /tmp/fm-live-agy/lib.sh
reset_fixture
poolconf acct-a acct-b
for a in acct-a acct-b; do
  mkuser "$a" gemini-flash-4-low
  usage "$a" 70
  catalog "$a" "$now" gemini-flash-4-low
done
echo "=== same account back-to-back with PACING=3 must not be gapped ==="
: > "$FX/calls.log"
FM_TASK_ID=live-s6b-1 runpool FM_AGY_PACING_SEC=3 -- --user acct-a --model gemini-flash-4-low -p task >/dev/null 2>&1
FM_TASK_ID=live-s6b-2 runpool FM_AGY_PACING_SEC=3 -- --user acct-a --model gemini-flash-4-low -p task >/dev/null 2>&1
grep '\-p /usage' "$FX/calls.log"
python3 /tmp/fm-live-agy/check_pacing.py "$FX/calls.log" 3 2>&1 | tail -4
echo "--- wall clock of the two runs:"
ns=$(date +%s%3N); FM_TASK_ID=live-s6b-3 runpool FM_AGY_PACING_SEC=3 -- --user acct-a --model gemini-flash-4-low -p task >/dev/null 2>&1; ne=$(date +%s%3N)
echo "one-run wall_ms=$(( ne - ns ))"
