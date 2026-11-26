#!/usr/bin/env bash
set -uo pipefail
. /tmp/fm-live-agy/lib.sh
reset_fixture
poolconf acct-a
mkuser acct-a gemini-flash-4-low
rm -f "$FX/home/acct-a/usage.txt"   # /usage fails: account unreadable right now
catalog acct-a "$now" gemini-flash-4-low

echo "=== run: live /usage fails; route line must say unknown, not an estimate ==="
rc=0; out=$(FM_TASK_ID=live-s9 runpool -- --model gemini-flash-4-low -p task) || rc=$?
echo "exit=$rc"; printf '%s\n' "$out"
echo "--- usage log"; jq -c '{user,event,decision,gemini_min_pct}' "$FX/usage.jsonl"
