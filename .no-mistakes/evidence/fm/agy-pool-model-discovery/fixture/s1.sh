#!/usr/bin/env bash
set -uo pipefail
. /tmp/fm-live-agy/lib.sh
reset_fixture
poolconf acct-a acct-b
mkuser acct-a gemini-hydrogen-4-high gemini-flash-4
mkuser acct-b gemini-hydrogen-4-high gemini-flash-4
usage acct-a 72
usage acct-b 90
catalog acct-a "$now" gemini-hydrogen-4-high gemini-flash-4
catalog acct-b "$(( now - 300 ))" gemini-hydrogen-4-high gemini-flash-4
printf 'acct-a\n' > "$FX/state/last-active"
chmod 0666 "$FX/state/last-active"

echo "=== run: model with hydrogen on both, last-active acct-a (72%) ==="
rc=0
out=$(FM_TASK_ID=live-s1 runpool -- --model gemini-hydrogen-4-high -p "do the task") || rc=$?
echo "exit=$rc"
echo "--- pool stderr/stdout"; printf '%s\n' "$out"
echo "--- live agy calls"; cat "$FX/calls.log"
echo "--- usage log"; jq -c . "$FX/usage.jsonl"
echo "--- state dir"; ls "$FX/state"
