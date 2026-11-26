#!/usr/bin/env bash
set -uo pipefail
. /tmp/fm-live-agy/lib.sh
reset_fixture
poolconf acct-a acct-b acct-c
for a in acct-a acct-b acct-c; do
  mkuser "$a" gemini-flash-4-low
  usage "$a" 60
  catalog "$a" "$now" gemini-flash-4-low
done
# Last saved quota readings: a=30, b=80, c=50; no sticky account yet.
printf '{"user":"acct-a","window_start":1,"reset_at":0,"used_sec":0,"budget_sec":5400,"exhausted":false,"quota":{"Gemini Models":{"min_pct":30,"reset_at":0}}}\n' > "$FX/state/acct-a.state.json"
printf '{"user":"acct-b","window_start":1,"reset_at":0,"used_sec":0,"budget_sec":5400,"exhausted":false,"quota":{"Gemini Models":{"min_pct":80,"reset_at":0}}}\n' > "$FX/state/acct-b.state.json"
printf '{"user":"acct-c","window_start":1,"reset_at":0,"used_sec":0,"budget_sec":5400,"exhausted":false,"quota":{"Gemini Models":{"min_pct":50,"reset_at":0}}}\n' > "$FX/state/acct-c.state.json"

echo "=== run: no last-active account; saved readings a=30 b=80 c=50 -> fallback order ==="
rc=0; out=$(FM_TASK_ID=live-s3 runpool -- --model gemini-flash-4-low -p task) || rc=$?
echo "exit=$rc"; printf '%s\n' "$out"
echo "--- usage log"; jq -c '{user,event,decision,gemini_min_pct}' "$FX/usage.jsonl"
