# Live validation notes - agy account pool for every task shape

Change: `fm/fm-agy-pool-all-paths` at `fcda9880` (base `d6fcddd5`), real host with the
production agy pool (`/etc/firstmate/gpro-pool.conf`: piyushjiit, piyushk, deepak, ...,
all signed in) and `agy` 1.5.14 on PATH.

Method: disposable firstmate lab homes minted with `bin/fm-lab-home.sh create`, driven
from a private tmux server (`TMUX_TMPDIR=<lab>/tmux tmux -L fm-lab`), one real
`bin/fm-spawn.sh` per scenario. The lab home was made production-shaped (group `agents`
with setgid, operator traverse ACL) so the real pool account could write its status and
report; that is fixture parity with the fleet home, not a product change. Each lab and
every worktree, task temp dir, and trust-store entry it created was removed at the end.

## Scenarios and what was observed

### 1. Scout on a named pool account (the intent's concrete case)
`bin/fm-spawn.sh scout1 <lab>/projects/demo --scout --harness agy --model
gemini-4-hydrogen-medium --effort low --account piyushk`
- spawn line: `spawned scout1 harness=agy kind=scout ... account=piyushk`
- `state/scout1.meta`: `kind=scout`, `account=piyushk`
- the live worker process was `/usr/local/bin/agy ...` running as user `piyushk`, with
  `FM_AGY_USER=piyushk` in the launcher command line
- the scout wrote its report as `piyushk`
- evidence: `live-shapes-snapshot.log`, `acct-*.log` (gate checks), plus the pane
  transcripts below

### 2. direct-PR ship routes through the pool (the reversed old test)
`bin/fm-spawn.sh dpr1 <demo> --mode direct-PR --yolo off --harness agy ...`
(no `--account`, automatic pool choice) -> `spawned dpr1 ... mode=direct-PR`, worker
`agy` running as `piyushk`.
`bin/fm-spawn.sh dpr2 ... --account piyushk` -> meta records `account=piyushk`; worker
`agy` as `piyushk`; it committed `NOTES.md` on `fm/dpr2` and reported done; the armed
`fm-pool-exit.sh dpr2` poller then stopped it, and the commit stayed.
evidence: `live-shapes-snapshot.log`, `live-direct-pr-pool-exit.log`

### 3. local-only ship routes through the pool
`bin/fm-spawn.sh loc1 <demo> --mode local-only --yolo off --harness agy --account piyushk`
-> `spawned loc1 ... mode=local-only`, meta `account=piyushk`, live `agy` as `piyushk`.
evidence: `live-shapes-snapshot.log`

### 4. Non-agy harness unchanged on a pool home
`bin/fm-spawn.sh cl1 <demo> --scout --harness claude --effort low`
-> `spawned cl1 harness=claude kind=scout`, no `account=` in meta, plain `claude`
process as the operator, no `agy-pool/agy` process.
evidence: `live-claude-scout.log`

### 5. Home with no pool config keeps the plain operator agy launch
`POOL_CONF=<lab>/no-pool.conf bin/fm-spawn.sh np1 <demo> --scout --harness agy ...`
-> plain `/usr/local/bin/agy` as `agentic`, no `account=` in meta, no pool launcher.
evidence: `live-no-pool-home.log`

### 6. Bad named accounts are refused and never substituted (adversarial)
- `--account nobody` -> `[fm-agy-pool] ERROR: 'nobody' is not an account in ...`
- `--account deepak --model gemini-4-hydrogen-medium` -> `not allowed for model ...`
- `--account piyushjiit` (real pool state marks it exhausted) -> `is marked exhausted
  for model ...`, then `error: a5 cannot launch on agy pool account 'piyushjiit'`
- `--account piyushk` with `POOL_CONF` absent -> `needs a configured pool`
all exit 1, no pane, no task record.
evidence: `acct-unknown.log`, `acct-disallowed-for-model.log`,
`live-exhausted-account-refusal.log`, `acct-no-pool.log`, `acct-capacity-zero.log`

### 7. Capacity gate before any pane (adversarial)
`FM_AGY_MAX_ACTIVE=0 bin/fm-spawn.sh a5 ...` -> `1 pool accounts already active
(piyushk); cap is 0`, exit 75, no window created, no pool-state directory written.
evidence: `acct-capacity-zero.log`

### 8. Secondmate stays off the pool and refuses --account (captain's final decision)
- `bin/fm-spawn.sh sm1 <seed-home> --secondmate --harness agy --account gpro2` ->
  `error: --account applies to ships and scouts; ...`
- without `--account` -> `spawned sm1 harness=agy kind=secondmate`; worker was plain
  `/usr/local/bin/agy` as `agentic`, no `FM_AGY_USER`, no `agy-pool/agy`, meta
  `kind=secondmate`.
evidence: `live-secondmate-account-refusal.log`, `live-secondmate-plain.log`

### 9. Control-plane relaunch reuses the recorded pool account
`bin/fm-control.sh scout1 relaunch --note ...` -> `relaunched scout1 harness=agy
from=agy model=...`, `state/scout1.meta` still `account=piyushk`, and the replacement
`agy` process ran as `piyushk`.
evidence: `live-relaunch-recorded-account.log`

### 10. Restored spawn validation block (the round-4 regression)
Live refusals, every one exit 1 with its concrete error:
- ship without `--mode` -> `ship spawns require --mode ...`
- scout with `--mode` -> `--mode applies only to ship spawns ...`
- `--effort turbo` -> `--effort must be one of ...`
- `--traceparent` on a ship -> `--traceparent applies only to --secondmate spawns ...`
- `--mode no-mistakes-prod-only` -> `no-mistakes-prod-only is a registry policy ...`
evidence: `refusal-*.log`

### 11. Setup health check covers task paths and project clones
`bin/fm-agy-pool-setup.sh check` reported the ungranted project clone and missing
worktree ACLs; `apply` printed `fixed ACL (access + default) for ... on
<lab>/projects/demo` and the traverse fixes; `check` afterwards reported
`task directory ... reachable` for all nine accounts and `project clone ... writable`
for all nine. Remaining `check` failures in that log are the lab's deliberately absent
no-mistakes worktrees/gh config, not the pool steps.
evidence: `setup-check-before.log`, `setup-apply.log`, `setup-check-after.log`

### 12. Targeted behaviour tests (not live)
`tests/fm-agy-harness.test.sh`, `tests/fm-agy-pool.test.sh`, `tests/fm-pool-exit.test.sh`,
`tests/fm-agy-pool-setup.test.sh`, `tests/fm-task-delivery.test.sh`,
`tests/fm-spawn-batch.test.sh` all pass, covering the pool-builder brief requirement for
a no-mistakes agy ship, the scout-without-report pool-exit gate, read-only spawn gates,
and the restored delivery-contract refusals.
