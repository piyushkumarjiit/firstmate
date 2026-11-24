#!/usr/bin/env bash
# Behavior tests for bin/fm-pool-exit.sh (finished pool builders free their slot).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "not ok - $*"; exit 1; }
pass() { echo "ok - $*"; }

mkdir -p "$TMP/state"
cat > "$TMP/control" <<'EOS'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_LOG"
EOS
chmod +x "$TMP/control"
export FAKE_LOG="$TMP/log" FM_HOME="$TMP" FM_POOL_EXIT_CONTROL="$TMP/control"
touch "$TMP/state/t1.meta"

printf 'working [at=1]: x\n' > "$TMP/state/t1.status"
"$ROOT/bin/fm-pool-exit.sh" t1 --once && fail "exited a builder that was still working"
[ ! -s "$FAKE_LOG" ] || fail "control called while builder working"

printf 'done [at=2]: committed abc\nworking [at=3]: resumed\n' > "$TMP/state/t1.status"
"$ROOT/bin/fm-pool-exit.sh" t1 --once && fail "exited after a later working line"

printf 'working [at=1]: x\ndone [at=2]: committed abc\n' > "$TMP/state/t1.status"
"$ROOT/bin/fm-pool-exit.sh" t1 --once || fail "did not exit a finished builder"
[ "$(cat "$FAKE_LOG")" = "t1 exit" ] || fail "expected control 't1 exit', got: $(cat "$FAKE_LOG")"

: > "$FAKE_LOG"
FM_POOL_EXIT=off "$ROOT/bin/fm-pool-exit.sh" t1 --once
[ ! -s "$FAKE_LOG" ] || fail "FM_POOL_EXIT=off still exited"

rm "$TMP/state/t1.meta"
"$ROOT/bin/fm-pool-exit.sh" t1 --once
[ ! -s "$FAKE_LOG" ] || fail "exited a task with no record"
pass "fm-pool-exit.sh exits only a builder whose latest status is done"
echo FM_TEST_COMPLETE
