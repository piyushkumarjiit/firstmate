#!/usr/bin/env bash
set -uo pipefail
. /tmp/fm-live-agy/lib.sh
reset_fixture
poolconf acct-a acct-b
mkuser acct-a gemini-flash-4-low
mkuser acct-b gemini-flash-4-low gemini-neon-4-high
usage acct-a 95; usage acct-b 40
catalog acct-a "$now" gemini-flash-4-low
catalog acct-b "$now" gemini-flash-4-low gemini-neon-4-high
printf 'acct-a\nacct-b\n' > "$FX/active"       # at cap
printf '{"user":"acct-a","window_start":1,"reset_at":0,"used_sec":0,"budget_sec":5400,"exhausted":false,"quota":{"Gemini Models":{"min_pct":95,"reset_at":0}}}\n' > "$FX/state/acct-a.state.json"
printf '{"user":"acct-b","window_start":1,"reset_at":0,"used_sec":0,"budget_sec":5400,"exhausted":false,"quota":{"Gemini Models":{"min_pct":40,"reset_at":0}}}\n' > "$FX/state/acct-b.state.json"

echo "=== at the cap, a Neon request must reuse the only Neon-capable active account, not the richer one ==="
rc=0; out=$(FM_TASK_ID=live-s7b runpool -- --model gemini-neon-4-high -p task) || rc=$?
echo "exit=$rc"; printf '%s\n' "$out"
echo "--- usage log"; jq -c '{user,event,decision,gemini_min_pct}' "$FX/usage.jsonl"

echo
echo "=== at the cap, a model no active account serves must refuse (exit 75), never substitute ==="
rc=0; out=$(FM_TASK_ID=live-s7c runpool -- --model gemini-hydrogen-4-high -p task) || rc=$?
echo "exit=$rc"; printf '%s\n' "$out"
