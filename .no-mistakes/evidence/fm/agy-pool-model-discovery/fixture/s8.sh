#!/usr/bin/env bash
set -uo pipefail
. /tmp/fm-live-agy/lib.sh
reset_fixture
poolconf acct-a acct-b
for a in acct-a acct-b; do
  mkuser "$a" gemini-flash-4-low
  usage "$a" 66
  catalog "$a" "$now" gemini-flash-4-low
done
printf 'acct-a\nacct-b\n' > "$FX/active"

echo "=== run: explicit --user acct-a while acct-a is already active ==="
rc=0; out=$(FM_TASK_ID=live-s8 runpool -- --user acct-a --model gemini-flash-4-low -p task) || rc=$?
echo "exit=$rc"; printf '%s\n' "$out"
echo "--- usage log"; jq -c '{user,event,decision,gemini_min_pct}' "$FX/usage.jsonl"
