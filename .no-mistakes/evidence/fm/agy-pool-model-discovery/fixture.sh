#!/usr/bin/env bash
# Disposable fixture builder for driving the real bin/agy-pool/agy launcher.
# The launcher, its state files, lock, selection and JSONL logging are the real
# product. Only the un-mintable external boundary is faked here: the set of
# separate signed-in Google accounts (fake sudo/id/pgrep + a stub agy that
# answers `models` and `-p /usage` for a named account).
set -euo pipefail

export FIX=$1
mkdir -p "$FIX/bin" "$FIX/state" "$FIX/home"

cat > "$FIX/bin/id" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-u" ]; then exec /usr/bin/id "$@"; fi
exit 0
EOF
cat > "$FIX/bin/sudo" <<'EOF'
#!/usr/bin/env bash
T=""
while [ $# -gt 0 ]; do
  case "$1" in
    -n|-H) shift ;;
    -u) T="$2"; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
if [ "${1:-}" = "test" ]; then exit 0; fi
SUDO_TARGET_USER="$T" exec "$@"
EOF
cat > "$FIX/bin/fake-pgrep" <<'EOF'
#!/usr/bin/env bash
acct=""
while [ $# -gt 0 ]; do
  case "$1" in
    -u) acct="$2"; shift 2 ;;
    *) shift ;;
  esac
done
grep -Fxq "$acct" "$FIX/active" 2>/dev/null
EOF
cat > "$FIX/bin/agy" <<'EOF'
#!/usr/bin/env bash
FIX="${FIX:-$(cd "$(dirname "$0")/.." && pwd)}"
acct="${SUDO_TARGET_USER:-unknown}"
printf '%s\t%s\t%s\n' "$(date +%s%3N)" "$acct" "$*" >> "$FIX/calls.log"
if [ "${1:-}" = "models" ]; then
  echo "Fetching available models..."
  cat "$FIX/catalog-$acct.txt" 2>/dev/null || exit 1
  exit 0
fi
if [ "${1:-}" = "-p" ] && [ "${2:-}" = "/usage" ]; then
  cat "$FIX/usage-$acct.txt" 2>/dev/null || exit 1
  exit 0
fi
echo "STUB_AGY_RAN for $acct"
exit 0
EOF
chmod +x "$FIX/bin/id" "$FIX/bin/sudo" "$FIX/bin/fake-pgrep" "$FIX/bin/agy"
: > "$FIX/active"
: > "$FIX/calls.log"

cat > "$FIX/run-pool" <<EOF
#!/usr/bin/env bash
exec env PATH="$FIX/bin:\$PATH" \\
  POOL_CONF="$FIX/pool.conf" MODELS_CONF="$FIX/legacy-models.conf" \\
  AGY_BIN="$FIX/bin/agy" FM_AGY_STATE_DIR="$FIX/state" \\
  FM_AGY_USAGE_LOG="$FIX/usage.jsonl" \\
  FM_AGY_PGREP="$FIX/bin/fake-pgrep" \\
  FM_AGY_PACING_SEC="\${FM_AGY_PACING_SEC:-0}" \\
  FM_HOME="$FIX/home" FM_TASK_ID="\${FM_TASK_ID:-fixlive}" FIX="$FIX" \\
  HOME="$FIX/home" $LAUNCHER "\$@"
EOF
chmod +x "$FIX/run-pool"

printf 'gemini-3.8-flash-high\tGemini 3.8 Flash (High)\ngemini-4-hydrogen-high\tGemini 4 Hydrogen (High)\n' > "$FIX/catalog-acct_a.txt"
cp "$FIX/catalog-acct_a.txt" "$FIX/catalog-acct_b.txt"
cp "$FIX/catalog-acct_a.txt" "$FIX/catalog-acct_c.txt"
printf 'gemini-4-neon-high\tGemini 4 Neon (High)\ngemini-4-hydrogen-high\tGemini 4 Hydrogen (High)\ngemini-3.8-flash-high\tGemini 3.8 Flash (High)\n' > "$FIX/catalog-neon1.txt"
printf 'gemini-4-hydrogen-high\tGemini 4 Hydrogen (High)\ngemini-3.8-flash-high\tGemini 3.8 Flash (High)\n' > "$FIX/catalog-plain1.txt"

write_usage() {
  printf 'Gemini Models\tWeekly Limit Remaining\t%s%%\t2027-12-03T13:51:31Z\n' "$2" > "$FIX/usage-$1.txt"
  printf 'Gemini Models\tFive Hour Limit Remaining\t%s%%\t2027-11-26T18:51:31Z\n' "$2" >> "$FIX/usage-$1.txt"
}
write_usage acct_a 85
write_usage acct_b 70
write_usage acct_c 45
write_usage neon1 95
write_usage plain1 50
echo "fixture ready at $FIX"
