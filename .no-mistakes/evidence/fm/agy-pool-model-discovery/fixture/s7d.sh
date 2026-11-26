#!/usr/bin/env bash
set -uo pipefail
. /tmp/fm-live-agy/lib.sh
reset_fixture
poolconf acct-a acct-b
for a in acct-a acct-b; do mkuser "$a" gemini-flash-4-low; catalog "$a" "$now" gemini-flash-4-low; done
rm -f "$FX/home/acct-b/usage.txt"     # the reused account's live /usage fails
printf 'acct-a\nacct-b\n' > "$FX/active"
printf '{"user":"acct-b","window_start":1,"reset_at":0,"used_sec":0,"budget_sec":5400,"exhausted":false,"quota":{"Gemini Models":{"min_pct":90,"reset_at":0}}}\n' > "$FX/state/acct-b.state.json"

echo "=== at the cap, the reused account's live /usage fails -> start reading is 'unknown' ==="
rc=0; out=$(FM_TASK_ID=live-s7d runpool -- --model gemini-flash-4-low -p task) || rc=$?
echo "exit=$rc"; printf '%s\n' "$out"
echo "--- usage log"; jq -c '{user,event,decision,gemini_min_pct}' "$FX/usage.jsonl"
