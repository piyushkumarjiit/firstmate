#!/usr/bin/env bash
# Live lab runner: drives the real bin/fm-deliver.sh end-to-end for each scenario.
set -u
LAB="$1"
WT="$2"
EVID="$3"
TARGET="$WT/bin/fm-deliver.sh"
BASE="$LAB/base-bin/fm-deliver.sh"

mkdir -p "$EVID"

new_fixture() {  # <dir>
  local R="$1" s
  s=$(basename "$R")
  rm -rf "$R"
  mkdir -p "$R/state" "$R/data/$s" "$R/config" "$R/bin" "$R/sc" "$R/nmhome" "$R/out" "$R/wt"
  git -C "$R/wt" init -q -b "fm/$s"
  git -C "$R/wt" config user.email "lab@example.test"
  git -C "$R/wt" config user.name "Lab"
  git -C "$R/wt" config commit.gpgsign false
  echo "feature" > "$R/wt/feature.txt"
  git -C "$R/wt" add -A
  git -C "$R/wt" commit -q -m "build: feature"
  git -C "$R/wt" rev-parse HEAD > "$R/sha"
  cat > "$R/state/$s.meta" <<EOF
endpoint_task_id=$s
worktree=$R/wt
branch=fm/$s
mode=local-only
EOF
  cat > "$R/data/$s/brief.md" <<'EOF'
# Task
## Captain's intent
Ship the feature.
EOF
  printf 'done [at=1000]: committed %s\n' "$(cat "$R/sha")" > "$R/state/$s.status"
  cat > "$R/bin/no-mistakes" <<'SH'
#!/usr/bin/env bash
S="$FAKE_SCEN"
ts() { date +%s%N; }
n_of() { local n; n=$(cat "$S/$1.count" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$S/$1.count"; echo "$n"; }
pick() { local n=$2 f; f="$S/$1.$n"; [ -f "$f" ] || f=$(ls "$S/$1".[0-9]* 2>/dev/null | sort -V | tail -1); [ -n "$f" ] && cat "$f"; }
cmd="${1:-} ${2:-}"
case "$cmd" in
  "axi status") n=$(n_of status); printf '%s status %s\n' "$(ts)" "$n" >> "$S/calls.log"; pick status "$n"; exit 0 ;;
  "axi run")    n=$(n_of run);    printf '%s run %s\n' "$(ts)" "$n" >> "$S/calls.log"; pick run "$n"; exit 0 ;;
  "axi respond") printf '%s respond\n' "$(ts)" >> "$S/calls.log"; cat "$S/respond.out" 2>/dev/null; exit "$(cat "$S/respond.rc" 2>/dev/null || echo 0)" ;;
  "axi sync"|"axi abort") printf '%s %s\n' "$(ts)" "$cmd" >> "$S/calls.log"; exit 0 ;;
esac
printf '%s other %s\n' "$(ts)" "$*" >> "$S/calls.log"
exit 0
SH
  chmod +x "$R/bin/no-mistakes"
}

# run the real driver: run_deliver <fixture-dir> <deliver-bin> <args...>
# optional env assignments come from the DELIVER_ENV array
DELIVER_ENV=()
run_deliver() {
  local R="$1" bin="$2" s; shift 2
  s=$(basename "$R")
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
      -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
      "${DELIVER_ENV[@]}" \
      PATH="$R/bin:$PATH" FAKE_SCEN="$R/sc" FM_HOME="$R" \
      FM_STATE_OVERRIDE="$R/state" FM_DATA_OVERRIDE="$R/data" FM_CONFIG_OVERRIDE="$R/config" \
      NM_HOME="$R/nmhome" FM_MAIN_USER="$(id -un)" FM_DELIVER_FOREGROUND=1 \
      FM_DELIVER_TAB=off "$bin" "$s" "$@"
}

report() {  # <fixture-dir> <label>
  local R="$1" label="$2" s; s=$(basename "$R")
  echo "--- $label ---"
  echo "[state/$s.status]"
  sed 's/^/  /' "$R/state/$s.status"
  echo "[data/$s/drive.log]"
  tail -40 "$R/data/$s/drive.log" 2>/dev/null | sed 's/^/  /'
  echo
}

########################## S1: later gates surface ##########################
seed_gate_surface() {  # <dir>
  local R="$1"
  printf '1' > "$R/sc/respond.rc"
  printf 'run:\n  id: "01R"\n  status: running\n' > "$R/sc/status.1"
  printf 'run:\n  id: "01R"\n  status: running\n' > "$R/sc/status.2"
  printf 'run:\n  id: "01R"\n  status: awaiting_approval\ngate:\n  step: document\n  summary: 2 ask-user findings\n' > "$R/sc/status.3"
  printf 'run:\n  id: "01R"\n  status: running\n' > "$R/sc/status.4"
  printf 'run:\n  id: "01R"\n  status: awaiting_approval\ngate:\n  step: ci\n  summary: checks failed\n' > "$R/sc/status.5"
  : > "$R/sc/run.1"; : > "$R/sc/run.2"
  echo 'needs-decision [at=100] [key=gate-review]: review findings' >> "$R/state/$(basename "$R").status"
}

for kind in target base; do
  R="$LAB/run/s1-$kind"; new_fixture "$R"; seed_gate_surface "$R"
  bin="$TARGET"; [[ "$kind" == base ]] && bin="$BASE"
  DELIVER_ENV=(FM_DELIVER_REATTACH_PAUSE=0)
  set +e
  run_deliver "$R" "$bin" respond --action approve >"$R/out/respond1.out" 2>&1; rc1=$?
  rc2=skipped
  if [[ "$kind" == target ]]; then
    printf '0' > "$R/sc/respond.rc"
    run_deliver "$R" "$bin" respond --action approve >"$R/out/respond2.out" 2>&1; rc2=$?
  fi
  set -e 2>/dev/null || true
  {
    if [[ "$kind" == target ]]; then
      echo "S1 live: later gates surface after a respond that exits nonzero"
    else
      echo "S1 baseline: SAME scenario against the pre-change driver (base commit a4860ac)"
    fi
    echo "product: $bin"
    echo "respond#1 exit=$rc1 ; respond#2 exit=$rc2"
    report "$R" "observable state"
    echo "[gate keys in the status log, in order]"
    grep -oE '(needs-decision|resolved).*\[key=gate-[a-z]*\]' "$R/state/$(basename "$R").status" | sed 's/^/  /'
  } > "$EVID/s1-gate-surface-$kind.txt"
done

########################## S2: same gate stays open ##########################
for kind in target base; do
  R="$LAB/run/s2-$kind"; new_fixture "$R"
  printf '1' > "$R/sc/respond.rc"
  printf 'run:\n  id: "01R"\n  status: awaiting_approval\ngate:\n  step: review\n  summary: 1 error finding\n' > "$R/sc/status.1"
  printf 'run:\n  id: "01R"\n  status: awaiting_approval\ngate:\n  step: review\n  summary: 1 error finding\n' > "$R/sc/status.2"
  echo 'needs-decision [at=100] [key=gate-review]: review findings' >> "$R/state/$(basename "$R").status"
  bin="$TARGET"; [[ "$kind" == base ]] && bin="$BASE"
  DELIVER_ENV=(FM_DELIVER_REATTACH_PAUSE=0)
  set +e
  run_deliver "$R" "$bin" respond --action approve >"$R/out/respond.out" 2>&1; rc=$?
  set -e 2>/dev/null || true
  {
    echo "S2 live (adversarial): a refused answer that leaves the run on the SAME gate must keep that gate open"
    echo "product: $bin  respond exit=$rc"
    report "$R" "observable state"
    echo "[check] resolved lines: $(grep -c '^resolved' "$R/state/$(basename "$R").status") (expected 0)"
    echo "[check] open review gate still last: $(tail -1 "$R/state/$(basename "$R").status")"
  } > "$EVID/s2-same-gate-$kind.txt"
done

########################## S3: green PR via reattach ##########################
seed_green_reattach() { local R="$1" sha; sha=$(cat "$R/sha")
  printf 'run:\n  id: "01R"\n  status: running\n  head_sha: "%s"\n' "$sha" > "$R/sc/status.1"
  printf 'run:\n  id: "01R"\n  status: running\n  head_sha: "%s"\n' "$sha" > "$R/sc/status.2"
  : > "$R/sc/run.1"
  printf 'outcome: checks-passed\npr: https://forge.example.test/o/r/pull/7\n' > "$R/sc/run.2"
}
for kind in target base; do
  R="$LAB/run/s3-$kind"; new_fixture "$R"; seed_green_reattach "$R"
  bin="$TARGET"; [[ "$kind" == base ]] && bin="$BASE"
  DELIVER_ENV=(FM_DELIVER_REATTACH_PAUSE=0 FM_DELIVER_REATTACH_MAX=4)
  set +e
  run_deliver "$R" "$bin" run >"$R/out/run.out" 2>&1; rc=$?
  set -e 2>/dev/null || true
  {
    if [[ "$kind" == target ]]; then
      echo "S3 live: a reattach that returns checks-passed + PR reports the PR ready, never blocked"
    else
      echo "S3 baseline: SAME scenario against the pre-change driver (base commit a4860ac)"
    fi
    echo "product: $bin  exit=$rc"
    report "$R" "observable state"
    echo "[check] last status line: $(tail -1 "$R/state/$(basename "$R").status")"
  } > "$EVID/s3-green-pr-$kind.txt"
done

########################## S4: checks-passed only in status ##########################
seed_green_status() { local R="$1" sha; sha=$(cat "$R/sha")
  printf 'run:\n  id: "01R"\n  status: running\n' > "$R/sc/status.1"
  printf 'run:\n  id: "01R"\n  status: running\n' > "$R/sc/status.2"
  printf 'run:\n  id: RUN1\n  status: running\n  head_sha: "%s"\noutcome: checks-passed\npr: https://forge.example.test/o/r/pull/11\n' "$sha" > "$R/sc/status.3"
  : > "$R/sc/run.1"
}
for kind in target base; do
  R="$LAB/run/s4-$kind"; new_fixture "$R"; seed_green_status "$R"
  bin="$TARGET"; [[ "$kind" == base ]] && bin="$BASE"
  DELIVER_ENV=(FM_DELIVER_REATTACH_PAUSE=0 FM_DELIVER_REATTACH_MAX=4)
  set +e
  run_deliver "$R" "$bin" run >"$R/out/run.out" 2>&1; rc=$?
  set -e 2>/dev/null || true
  {
    echo "S4 live: checks-passed + PR visible in axi status is also reported as the PR ready"
    echo "product: $bin  exit=$rc"
    report "$R" "observable state"
    echo "[check] last status line: $(tail -1 "$R/state/$(basename "$R").status")"
  } > "$EVID/s4-green-status-$kind.txt"
done

########################## S5: stale log outcome is ignored ##########################
for kind in target base; do
  R="$LAB/run/s5-$kind"; new_fixture "$R"
  printf 'run:\n  id: "01R"\n  status: running\n' > "$R/sc/status.1"
  : > "$R/sc/run.1"
  cat > "$R/data/$(basename "$R")/drive.log" <<'EOF'
[fm-deliver] older run in this task
outcome: checks-passed
pr: https://forge.example.test/o/r/pull/3
EOF
  bin="$TARGET"; [[ "$kind" == base ]] && bin="$BASE"
  DELIVER_ENV=(FM_DELIVER_REATTACH_PAUSE=0 FM_DELIVER_REATTACH_MAX=3)
  set +e
  run_deliver "$R" "$bin" run >"$R/out/run.out" 2>&1; rc=$?
  set -e 2>/dev/null || true
  {
    echo "S5 live (adversarial): an older run's checks-passed line in the shared drive log is never read as this run's green PR"
    echo "product: $bin  exit=$rc"
    report "$R" "observable state"
    echo "[check] last status line: $(tail -1 "$R/state/$(basename "$R").status")"
  } > "$EVID/s5-stale-log-$kind.txt"
done

########################## S6: reattach pacing ##########################
for kind in target base; do
  R="$LAB/run/s6-$kind"; new_fixture "$R"
  printf 'run:\n  id: "01R"\n  status: running\n' > "$R/sc/status.1"
  : > "$R/sc/run.1"
  bin="$TARGET"; [[ "$kind" == base ]] && bin="$BASE"
  DELIVER_ENV=(FM_DELIVER_REATTACH_PAUSE=1 FM_DELIVER_REATTACH_MAX=4)
  t0=$(date +%s%N)
  set +e
  run_deliver "$R" "$bin" run >"$R/out/run.out" 2>&1; rc=$?
  set -e 2>/dev/null || true
  t1=$(date +%s%N)
  elapsed_ms=$(( (t1 - t0) / 1000000 ))
  {
    if [[ "$kind" == target ]]; then
      echo "S6 live: an immediately-returning reattach backs off instead of burning the budget at once"
    else
      echo "S6 baseline: SAME scenario against the pre-change driver (base commit a4860ac)"
    fi
    echo "product: $bin  exit=$rc  elapsed_ms=$elapsed_ms (4 reattaches, 1s pause => >=3000ms)"
    report "$R" "observable state"
    echo "[reattach calls, nanosecond timestamps]"
    grep ' run ' "$R/sc/calls.log" | sed 's/^/  /'
  } > "$EVID/s6-pacing-$kind.txt"
done

########################## S7: open gate beats a green outcome ##########################
for kind in target base; do
  R="$LAB/run/s7-$kind"; new_fixture "$R"
  printf 'run:\n  id: "01R"\n  status: awaiting_approval\ngate:\n  step: document\n  summary: 2 ask-user findings\n' > "$R/sc/status.1"
  printf 'run:\n  id: "01R"\n  status: awaiting_approval\ngate:\n  step: document\n  summary: 2 ask-user findings\n' > "$R/sc/status.2"
  printf 'outcome: checks-passed\npr: https://forge.example.test/o/r/pull/9\n' > "$R/sc/run.1"
  bin="$TARGET"; [[ "$kind" == base ]] && bin="$BASE"
  DELIVER_ENV=(FM_DELIVER_REATTACH_PAUSE=0 FM_DELIVER_REATTACH_MAX=4)
  set +e
  run_deliver "$R" "$bin" run >"$R/out/run.out" 2>&1; rc=$?
  set -e 2>/dev/null || true
  {
    echo "S7 live (adversarial): an open gate is surfaced as needs-decision, never hidden behind a checks-passed outcome"
    echo "product: $bin  exit=$rc"
    report "$R" "observable state"
    echo "[check] last status line: $(tail -1 "$R/state/$(basename "$R").status")"
  } > "$EVID/s7-gate-beats-green-$kind.txt"
done

echo done

########################## S8: real captured parked gate is surfaced ##########################
# status.3 here is the repo's byte-authentic capture of a real `axi status` parked
# gate (tests/captures/no-mistakes-v1.70.1/parked.toon), with only the documented
# replay substitutions (run id, branch, head) so it binds to this disposable repo.
CAP="$WT/tests/captures/no-mistakes-v1.70.1/parked.toon"
for kind in target base; do
  R="$LAB/run/s8-$kind"; new_fixture "$R"; sha=$(cat "$R/sha")
  printf '1' > "$R/sc/respond.rc"
  printf 'run:\n  id: "01R"\n  status: running\n' > "$R/sc/status.1"
  printf 'run:\n  id: "01R"\n  status: running\n' > "$R/sc/status.2"
  sed -e "s#^  id: \".*\"#  id: \"01REALCAPTURE\"#" \
      -e "s#^  branch: .*#  branch: fm/s8-$kind#" \
      -e "s#^  head: .*#  head: ${sha:0:8}#" \
      -e "s#^  head_sha: .*#  head_sha: $sha#" \
      "$CAP" > "$R/sc/status.3"
  : > "$R/sc/run.1"
  echo 'needs-decision [at=100] [key=gate-review]: review findings' >> "$R/state/$(basename "$R").status"
  bin="$TARGET"; [[ "$kind" == base ]] && bin="$BASE"
  DELIVER_ENV=(FM_DELIVER_REATTACH_PAUSE=0)
  set +e
  run_deliver "$R" "$bin" respond --action approve >"$R/out/respond.out" 2>&1; rc=$?
  set -e 2>/dev/null || true
  {
    echo "S8 live: a later gate in the repo's byte-authentic real axi-status capture is surfaced after a nonzero respond"
    echo "product: $bin  respond exit=$rc"
    echo "gate payload replayed from: tests/captures/no-mistakes-v1.70.1/parked.toon"
    report "$R" "observable state"
    echo "[gate keys in the status log, in order]"
    grep -oE '(needs-decision|resolved).*\[key=gate-[a-z]*\]' "$R/state/$(basename "$R").status" | sed 's/^/  /'
  } > "$EVID/s8-real-gate-$kind.txt"
done

echo done-real-gate
