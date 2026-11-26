#!/usr/bin/env bash
set -uo pipefail
. /tmp/fm-live-agy/lib.sh
reset_fixture
poolconf acct-a acct-b
mkuser acct-a gemini-flash-4-low gemini-hydrogen-4-high gemini-neon-4-high
mkuser acct-b gemini-flash-4-low gemini-hydrogen-4-high
usage acct-a 95; usage acct-b 40
catalog acct-a "$now" gemini-flash-4-low gemini-hydrogen-4-high gemini-neon-4-high
catalog acct-b "$now" gemini-flash-4-low gemini-hydrogen-4-high
printf 'acct-a\n' > "$FX/state/last-active"

for m in gemini-flash-4-low gemini-hydrogen-4-high gemini-neon-4-high; do
  echo "=== run: model $m (last-active acct-a is the only Neon-capable, 95%; acct-b non-Neon 40%) ==="
  rc=0; out=$(FM_TASK_ID="live-s5-$m" runpool -- --model "$m" -p task) || rc=$?
  echo "exit=$rc"; printf '%s\n' "$out"
done
echo "--- usage log"; jq -c '{user,model,event,decision,gemini_min_pct}' "$FX/usage.jsonl"
