#!/usr/bin/env bash
set -uo pipefail
. /tmp/fm-live-agy/lib.sh
reset_fixture
poolconf acct-a acct-b
mkuser acct-a gemini-flash-4 gemini-hydrogen-4-high
mkuser acct-b gemini-flash-4 gemini-hydrogen-4-high
usage acct-a 8      # last-active, but nearly out of quota
usage acct-b 65
catalog acct-a "$now" gemini-flash-4 gemini-hydrogen-4-high
catalog acct-b "$now" gemini-flash-4 gemini-hydrogen-4-high
printf 'acct-a\n' > "$FX/state/last-active"

echo "=== run: last-active acct-a has only 8% live (floor 15) -> must switch ==="
rc=0
out=$(FM_TASK_ID=live-s4 runpool -- --model gemini-hydrogen-4-high -p task) || rc=$?
echo "exit=$rc"; printf '%s\n' "$out"
echo "--- usage log"; jq -c '{user,event,decision,gemini_min_pct}' "$FX/usage.jsonl"
echo "--- acct-a state"; jq -c '{exhausted,reset_at}' "$FX/state/acct-a.state.json"
