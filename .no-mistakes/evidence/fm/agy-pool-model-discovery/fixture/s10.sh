#!/usr/bin/env bash
set -uo pipefail
. /tmp/fm-live-agy/lib.sh
gate() { local label=$1; shift; local rc=0 out; out=$(runpool -- "$@") || rc=$?;
  echo "--- $label -> exit $rc"; printf '%s\n' "$out" | sed 's/^/    /'; }

reset_fixture
poolconf acct-a acct-b
mkuser acct-a gemini-flash-4-low gemini-hydrogen-4-high
mkuser acct-b gemini-flash-4-low gemini-hydrogen-4-high
catalog acct-a "$now" gemini-flash-4-low gemini-hydrogen-4-high
catalog acct-b "$now" gemini-flash-4-low gemini-hydrogen-4-high
echo "=== spawn-time read-only gates (bin/fm-spawn.sh calls bin/agy-pool/agy --check-model/--check-account) ==="
gate "check-model listed in a fresh catalog" --check-model gemini-flash-4-low
gate "check-model absent from every fresh catalog" --check-model gemini-neon-4-high
gate "check-account fresh catalog omits model" --check-account acct-a gemini-neon-4-high
gate "check-account fresh catalog lists model" --check-account acct-a gemini-flash-4-low
echo "--- live agy invocations during gates (must be none):"; cat "$FX/calls.log"
echo "--- state dir after gates (must hold only the seeded catalogs):"; ls "$FX/state"

echo
echo "=== unknown catalogs (never fetched) allow the model unvalidated ==="
reset_fixture
poolconf acct-a
mkuser acct-a gemini-flash-4-low
gate "check-model with a missing catalog" --check-model gemini-neon-4-high
gate "check-account with a missing catalog" --check-account acct-a gemini-neon-4-high
echo "--- live agy invocations (must be none):"; cat "$FX/calls.log"
