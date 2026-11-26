#!/usr/bin/env bash
# Scenario: the machine-wide live-query lock spaces live queries on DIFFERENT
# accounts by PACING_SEC and never runs two of them at the same time, while a
# query on the SAME account is not gapped.
set -uo pipefail
ROOT=~/.no-mistakes/worktrees/406d2d249c60/01M8C175QRFR8PN3KCPEG4F3C7
LAUNCHER=$ROOT/bin/agy-pool/agy
FIX=$1
OUT=$2
mkdir -p "$OUT"
. /tmp/fm-live-scen/fixture.sh "$FIX" >/dev/null

# Wrap the stub so each live query logs an interval (start/end) and holds the
# lock for a moment, making any overlap observable.
cat > "$FIX/bin/agy" <<'EOF'
#!/usr/bin/env bash
FIX="${FIX:-$(cd "$(dirname "$0")/.." && pwd)}"
acct="${SUDO_TARGET_USER:-unknown}"
printf 'S\t%s\t%s\t%s\n' "$(date +%s%3N)" "$acct" "$*" >> "$FIX/calls.log"
if [ "${1:-}" = "models" ]; then
  echo "Fetching available models..."
  cat "$FIX/catalog-$acct.txt" 2>/dev/null || exit 1
  printf 'E\t%s\t%s\t%s\n' "$(date +%s%3N)" "$acct" "$*" >> "$FIX/calls.log"
  exit 0
fi
if [ "${1:-}" = "-p" ] && [ "${2:-}" = "/usage" ]; then
  sleep "${FIX_USAGE_SLEEP:-1}"
  cat "$FIX/usage-$acct.txt" 2>/dev/null || exit 1
  printf 'E\t%s\t%s\t%s\n' "$(date +%s%3N)" "$acct" "$*" >> "$FIX/calls.log"
  exit 0
fi
printf 'E\t%s\t%s\t%s\n' "$(date +%s%3N)" "$acct" "$*" >> "$FIX/calls.log"
echo "STUB_AGY_RAN for $acct"
exit 0
EOF
chmod +x "$FIX/bin/agy"

printf 'acct_a\nacct_b\n' > "$FIX/pool.conf"
: > "$FIX/legacy-models.conf"
now=$(date +%s)
for u in acct_a acct_b; do
  jq -nc --arg u "$u" --argjson ts "$now" \
    '{user:$u, fetched_at:$ts, models:["gemini-3.8-flash-high","gemini-4-hydrogen-high"]}' \
    > "$FIX/state/$u.models.json"
done

step() { printf '\n### %s\n' "$*"; }
gate_lines() { awk -F'\t' '$1=="S" && $4 ~ /^\-p \/usage/ {print}' "$FIX/calls.log"; }

step "two concurrent launches on DIFFERENT accounts with PACING_SEC=3"
: > "$FIX/calls.log"
FM_AGY_PACING_SEC=3 FIX_USAGE_SLEEP=1 \
  timeout 120 "$FIX/run-pool" --user acct_a --model gemini-3.8-flash-high -p hello >/dev/null 2>&1 &
p1=$!
sleep 0.2
FM_AGY_PACING_SEC=3 FIX_USAGE_SLEEP=1 \
  timeout 120 "$FIX/run-pool" --user acct_b --model gemini-3.8-flash-high -p hello >/dev/null 2>&1 &
p2=$!
wait "$p1"; r1=$?
wait "$p2"; r2=$?
echo "  exit codes: a=$r1 b=$r2"
echo "  call intervals:"; sed 's/^/    /' "$FIX/calls.log"

overlap_and_gap=$(awk -F'\t' '
  $1=="S" && $2 !~ /^$/ { }
  $1=="E" { }
  { }
  END { }
' "$FIX/calls.log" >/dev/null; true)
# compute with awk: list of [start,end] intervals, check no overlap, min gap
awk -F'\t' '
  $1=="S" { start[$3]=$2 }
  $1=="E" && $4 ~ /^\-p \/usage/ { printf "%s\t%s\t%s\n", start[$3], $2, $3 }
' "$FIX/calls.log" > "$OUT/scenario6-gate-intervals.tsv"
echo "  gate /usage intervals (start end account):"
sed 's/^/    /' "$OUT/scenario6-gate-intervals.tsv"

step "same-account query is not gapped: last live query was acct_a a moment ago"
first_ms=$(awk -F'\t' '$1=="S" && $4 ~ /^\-p \/usage/ {print $2; exit}' "$FIX/calls.log")
last_ms=$(awk -F'\t' '$1=="E" && $4 ~ /^\-p \/usage/ {print $2}' "$FIX/calls.log" | tail -n1)
# Pretend a live query on acct_a just happened, then run acct_a again and time the wait.
printf '%s\t%s\n' "$(date +%s)" acct_a > "$FIX/state/last-live-query"
: > "$FIX/calls.log"
start_ms=$(date +%s%3N)
FM_AGY_PACING_SEC=30 FIX_USAGE_SLEEP=0 \
  timeout 120 "$FIX/run-pool" --user acct_a --model gemini-3.8-flash-high -p hello >/dev/null 2>&1
same_wait_ms=$(( $(awk -F'\t' '$1=="S" && $4 ~ /^\-p \/usage/ {print $2; exit}' "$FIX/calls.log") - start_ms ))
echo "  same-account wait before its /usage: ${same_wait_ms}ms (PACING_SEC=30)"

step "different-account query is gapped: same last live query timestamp, run acct_b"
printf '%s\t%s\n' "$(date +%s)" acct_a > "$FIX/state/last-live-query"
: > "$FIX/calls.log"
start_ms=$(date +%s%3N)
FM_AGY_PACING_SEC=5 FIX_USAGE_SLEEP=0 \
  timeout 120 "$FIX/run-pool" --user acct_b --model gemini-3.8-flash-high -p hello >/dev/null 2>&1
diff_wait_ms=$(( $(awk -F'\t' '$1=="S" && $4 ~ /^\-p \/usage/ {print $2; exit}' "$FIX/calls.log") - start_ms ))
echo "  different-account wait before its /usage: ${diff_wait_ms}ms (PACING_SEC=5)"

step "ban-risk guard: a live /usage on a third account is refused while the cap is reached"
printf 'acct_a\nacct_b\n' > "$FIX/active"
: > "$FIX/calls.log"
set +e
FM_AGY_PACING_SEC=3 timeout 60 "$FIX/run-pool" --usage acct_c > "$OUT/scenario6-usage-cap.txt" 2>&1
usage_cap_rc=$?
set -e
: > "$FIX/active"
sed 's/^/  /' "$OUT/scenario6-usage-cap.txt"
echo "  exit=$usage_cap_rc agy calls=$(wc -l < "$FIX/calls.log")"

{
  echo "== concurrent cross-account gate intervals (start_ms end_ms account) =="
  cat "$OUT/scenario6-gate-intervals.tsv"
  echo
  echo "== full call log of the concurrent phase =="
  sed -n '1,40p' "$FIX/calls.log"
  echo
  echo "same-account wait=${same_wait_ms}ms; different-account wait=${diff_wait_ms}ms"
  echo "== --usage at the active cap =="
  cat "$OUT/scenario6-usage-cap.txt"
  echo "exit=$usage_cap_rc agy calls during refused check=$(wc -l < "$FIX/calls.log")"
} > "$OUT/scenario6-transcript.txt" 2>&1

fail=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }

gap_ms=$(awk -F'\t' 'NR==1{prev_end=$2} NR>1{printf "%d\n", $1-prev_end; exit}' "$OUT/scenario6-gate-intervals.tsv")
check "two different-account live queries never overlapped and were spaced >= PACING_SEC" \
  "awk -F'\t' 'NR==1{pe=\$2; next} {if (\$1 < pe) exit 1; if (\$1 - pe < 2800) exit 1; pe=\$2} END{exit 0}' \"$OUT/scenario6-gate-intervals.tsv\""
check "same-account reuse waited less than 2s despite PACING_SEC=30" \
  "[ \"$same_wait_ms\" -lt 2000 ]"
check "different-account reuse waited at least ~4s under PACING_SEC=5" \
  "[ \"$diff_wait_ms\" -ge 4000 ]"
check "a third account's live /usage is refused while two accounts are active" \
  "[ \"$usage_cap_rc\" -eq 75 ] && grep -q 'refusing live usage check' \"$OUT/scenario6-usage-cap.txt\" && [ ! -s \"$FIX/calls.log\" ]"
[ "$fail" -eq 0 ] && echo "SCENARIO6 PASS" || echo "SCENARIO6 FAIL"
exit "$fail"
