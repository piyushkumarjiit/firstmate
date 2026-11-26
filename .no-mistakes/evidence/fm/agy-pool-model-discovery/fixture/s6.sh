#!/usr/bin/env bash
set -uo pipefail
. /tmp/fm-live-agy/lib.sh
reset_fixture
poolconf acct-a acct-b acct-c
for a in acct-a acct-b acct-c; do
  mkuser "$a" gemini-flash-4-low
  usage "$a" 70
  # stale catalogs force a live `agy models` fetch per account too
  catalog "$a" "$(( now - 90000 ))" gemini-flash-4-low
done

echo "=== adversarial: 3 concurrent pool launches on 3 different accounts, PACING=3s ==="
: > "$FX/calls.log"
start=$(date +%s%3N)
for a in acct-a acct-b acct-c; do
  FM_TASK_ID="live-s6-$a" runpool FM_AGY_PACING_SEC=3 -- --user "$a" --model gemini-flash-4-low -p task > "$FX/out-$a.txt" 2>&1 &
done
wait
end=$(date +%s%3N)
echo "wall_ms=$(( end - start ))"
echo "--- per-run output"; for a in acct-a acct-b acct-c; do echo "[$a]"; cat "$FX/out-$a.txt"; done
echo "--- every live query (models + /usage) with start/end timestamps"
cat "$FX/calls.log"
python3 /tmp/fm-live-agy/check_pacing.py "$FX/calls.log" 3
