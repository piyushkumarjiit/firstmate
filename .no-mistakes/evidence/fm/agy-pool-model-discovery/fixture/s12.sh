#!/usr/bin/env bash
# Drive the real bin/fm-deliver.sh failover decision with a disposable task
# fixture. no-mistakes is the external boundary and is faked; git, the pool
# state/catalog files and fm-deliver itself are real.
set -uo pipefail
REPO=~/.no-mistakes/worktrees/406d2d249c60/01M8ARDM50Q2WJQFV62PZRT23G
DELIVER="$REPO/bin/fm-deliver.sh"
BASE=/tmp/fm-live-agy/deliverfx
rm -rf "$BASE"; mkdir -p "$BASE"

run_case() { # <name> <acct2_catalog_has_model yes|no> <expect_failover yes|no>
  local name=$1 acct2_has=$2 expect=$3
  local tdir="$BASE/$name"
  mkdir -p "$tdir/state" "$tdir/data/$name" "$tdir/wt" "$tdir/config" "$tdir/agy-state" "$tdir/bin" "$tdir/nmhome/logs/RUNQ"
  git -C "$tdir/wt" init -q -b "fm/$name"
  git -C "$tdir/wt" config user.email t@example.com
  git -C "$tdir/wt" config user.name Test
  echo content > "$tdir/wt/file.txt"
  git -C "$tdir/wt" add file.txt
  git -C "$tdir/wt" commit -q -m init
  local sha; sha=$(git -C "$tdir/wt" rev-parse HEAD)
  cat > "$tdir/state/$name.meta" <<META
endpoint_task_id=$name
worktree=$tdir/wt
branch=fm/$name
mode=local-only
META
  echo "done [at=1000]: committed $sha" > "$tdir/state/$name.status"
  printf "# Task\n## Captain's intent\nx\n## Firstmate spec\ny\n" > "$tdir/data/$name/brief.md"
  printf '{"roles":{"review":[{"harness":"agy","model":"gemini-m1-neon"},{"harness":"agy","model":"gemini-m2-flash"}]}}\n' > "$tdir/config/crew-dispatch.json"
  printf 'acct1\nacct2\n' > "$tdir/pool.conf"
  # acct1 serves m1 and is exhausted; acct2 is healthy
  printf '{"user":"acct1","window_start":1,"reset_at":0,"used_sec":0,"budget_sec":5400,"exhausted":true,"quota":{}}\n' > "$tdir/agy-state/acct1.state.json"
  printf '{"user":"acct2","window_start":1,"reset_at":0,"used_sec":0,"budget_sec":5400,"exhausted":false,"quota":{}}\n' > "$tdir/agy-state/acct2.state.json"
  local now; now=$(date +%s)
  printf '{"user":"acct1","fetched_at":%s,"models":["gemini-m1-neon","gemini-m2-flash"]}\n' "$now" > "$tdir/agy-state/acct1.models.json"
  if [ "$acct2_has" = yes ]; then
    printf '{"user":"acct2","fetched_at":%s,"models":["gemini-m1-neon","gemini-m2-flash"]}\n' "$now" > "$tdir/agy-state/acct2.models.json"
  else
    printf '{"user":"acct2","fetched_at":%s,"models":["gemini-m2-flash"]}\n' "$now" > "$tdir/agy-state/acct2.models.json"
  fi
  if [ "$expect" = yes ]; then
    printf "error: Individual quota reached\n[fm-agy-pool] Account 'acct1' hit quota exhaustion; marked exhausted until 1.\n" > "$tdir/nmhome/logs/RUNQ/review.log"
  else
    printf "error: review step failed for an unrelated reason\n" > "$tdir/nmhome/logs/RUNQ/review.log"
  fi
  cat > "$tdir/bin/no-mistakes" <<NM
#!/usr/bin/env bash
cmd="\${1:-} \${2:-}"
if [[ "\$cmd" == "axi run" ]]; then
  printf '%s\n' "\${FM_NM_REVIEW_MODEL:-}" >> "$tdir/run-models.log"
  [[ "\${FM_NM_REVIEW_MODEL:-}" == "gemini-m1-neon" ]] && : > "$tdir/failed_once"
  exit 0
elif [[ "\$cmd" == "axi status" ]]; then
  if [[ -f "$tdir/failed_once" && ! -f "$tdir/aborted" ]]; then
    printf 'run:\n  id: "RUNQ"\n  status: failed\noutcome: failed\n'
  else
    printf 'run:\n  id: "RUNP"\n  status: completed\noutcome: passed\nbranch_sync:\n  next_action:\n    command: "no-mistakes axi sync"\n'
  fi
elif [[ "\$cmd" == "axi abort" ]]; then : > "$tdir/aborted"; fi
exit 0
NM
  chmod +x "$tdir/bin/no-mistakes"
  PATH="$tdir/bin:$PATH" NM_HOME="$tdir/nmhome" FM_HOME="$tdir" \
    FM_STATE_OVERRIDE="$tdir/state" FM_DATA_OVERRIDE="$tdir/data" \
    FM_CONFIG_OVERRIDE="$tdir/config" FM_AGY_STATE_DIR="$tdir/agy-state" \
    POOL_CONF="$tdir/pool.conf" FM_MAIN_USER="$(id -un)" FM_DELIVER_FOREGROUND=1 \
    "$DELIVER" "$name" run > "$tdir/deliver.log" 2>&1
  local models; models=$(grep -c . "$tdir/run-models.log" 2>/dev/null || echo 0)
  echo "=== $name: acct2 fresh catalog lists m1: $acct2_has (expect failover: $expect)"
  echo "    axi run calls (one model per line):"; nl -ba "$tdir/run-models.log" 2>/dev/null | sed "s/^/      /"; echo "    deliver log tail:"; tail -8 "$tdir/deliver.log" | sed "s/^/      /"; echo "    status tail:"; tail -2 "$tdir/state/$name.status" | sed "s/^/      /"
  if [ "$expect" = yes ]; then
    if grep -q gemini-m2-flash "$tdir/run-models.log" 2>/dev/null; then echo "    RESULT: PASS (failed over to the next role model)"; else echo "    RESULT: FAIL (no failover)"; fi
  else
    if grep -q gemini-m2-flash "$tdir/run-models.log" 2>/dev/null; then echo "    RESULT: FAIL (should have stayed on m1)"; else echo "    RESULT: PASS (no failover: another account can still serve m1)"; fi
  fi
}

echo "=== fm-deliver role failover uses discovered per-account catalogs (no model map)"
run_case catalog_excludes_second_account no yes
run_case catalog_includes_second_account yes no
rm -rf "$BASE"
echo "fixture removed"
