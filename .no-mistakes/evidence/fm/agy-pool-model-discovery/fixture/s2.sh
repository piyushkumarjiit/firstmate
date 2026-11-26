#!/usr/bin/env bash
set -uo pipefail
. /tmp/fm-live-agy/lib.sh
reset_fixture
poolconf acct-a acct-b acct-c
# legacy hard-coded map claims Hydrogen lives on acct-b
printf '*hydrogen* acct-b\n' > "$FX/models.conf"
mkuser acct-a gemini-flash-4
mkuser acct-b gemini-flash-4 gemini-neon-4-high
mkuser acct-c gemini-hydrogen-4-high gemini-flash-4
usage acct-a 88; usage acct-b 85; usage acct-c 55
catalog acct-a "$now" gemini-flash-4
catalog acct-b "$now" gemini-flash-4 gemini-neon-4-high
# acct-c's catalog is stale (> TTL) so discovery must refresh just that account
catalog acct-c "$(( now - 90000 ))" gemini-flash-4 gemini-neon-4-high
printf 'acct-a\n' > "$FX/state/last-active"

echo "=== run: hydrogen model; legacy map says acct-b; only acct-c catalog lists it (stale) ==="
rc=0
out=$(FM_TASK_ID=live-s2 runpool -- --model gemini-hydrogen-4-high -p task) || rc=$?
echo "exit=$rc"
printf '%s\n' "$out"
echo "--- live agy calls"; cat "$FX/calls.log"
echo "--- acct-c catalog after run"; jq -c . "$FX/state/acct-c.models.json"
echo "--- other catalogs untouched (fetched_at)"; jq -r '[.user,.fetched_at]|join(" ")' "$FX/state/acct-a.models.json" "$FX/state/acct-b.models.json"
echo "--- usage log"; jq -c '{user,event,decision,gemini_min_pct}' "$FX/usage.jsonl"
