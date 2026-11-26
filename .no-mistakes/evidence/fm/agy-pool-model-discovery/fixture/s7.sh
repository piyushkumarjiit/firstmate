#!/usr/bin/env bash
set -uo pipefail
. /tmp/fm-live-agy/lib.sh
reset_fixture
poolconf acct-a acct-b
for a in acct-a acct-b; do
  mkuser "$a" gemini-flash-4-low
  usage "$a" 87
  catalog "$a" "$now" gemini-flash-4-low
done
printf 'acct-a\nacct-b\n' > "$FX/active"      # both accounts already running agy (at cap)
# saved readings order the active accounts: acct-b higher
printf '{"user":"acct-a","window_start":1,"reset_at":0,"used_sec":0,"budget_sec":5400,"exhausted":false,"quota":{"Gemini Models":{"min_pct":45,"reset_at":0}}}\n' > "$FX/state/acct-a.state.json"
printf '{"user":"acct-b","window_start":1,"reset_at":0,"used_sec":0,"budget_sec":5400,"exhausted":false,"quota":{"Gemini Models":{"min_pct":90,"reset_at":0}}}\n' > "$FX/state/acct-b.state.json"

echo "=== run: cap already reached (2 active); reuse must take a live start reading and print it ==="
rc=0; out=$(FM_TASK_ID=live-s7 runpool -- --model gemini-flash-4-low -p task) || rc=$?
echo "exit=$rc"; printf '%s\n' "$out"
echo "--- usage log"; jq -c '{user,event,decision,gemini_min_pct}' "$FX/usage.jsonl"
