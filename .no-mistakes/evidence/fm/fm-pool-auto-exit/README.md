# Live validation: finished agy pool builders exit to free their account slot

Change under test: `bin/fm-deliver.sh` exits a finished `builder=pool` `harness=agy`
builder through `bin/fm-control.sh <task> exit` once per committed sha, as
no-mistakes `run` starts.

## Lab (disposable, torn down in the same turn)

Minted with `bin/fm-lab-home.sh create` under `mktemp -d /tmp/fm-lab.XXXXXX`, with a
private tmux socket from `bin/fm-lab-home.sh tmux-dir`. Inside:

- Real `agy` 1.5.14 TUI (the installed `/usr/local/bin/agy`) launched into a tmux
  window named `fm-<task>` from a shell pane, exactly the shape `fm-spawn.sh`
  creates (`tmux new-window`, then the launch line is typed into the pane). The
  window's shell outlives the agent, so the endpoint survives an agent exit.
- A throwaway `HOME` holding a copy of `~/.gemini` (the documented agy live-test
  method), so trust answers and every agy write land in the lab, never the
  operator store.
- Task records in the lab `state/`: `harness=agy`, `builder=pool`, `window=lab:fm-<task>`,
  plus a git worktree whose HEAD equals the `done: committed <sha>` status line.
- `no-mistakes` on PATH is a logging stub: the surface under test is the slot
  release that happens *before* the validation run starts, not the no-mistakes
  pipeline itself.
- `pool.conf` lists the lab runner's own user as the single pool account, and the
  spawn-time capacity gate (`bin/fm-agy-pool.sh --check-capacity`, the same code
  the real `bin/agy-pool/agy --check-capacity` runs) reports the live agy process
  through `pgrep -u <account> -x agy`. The gate is invoked through `bash` so the
  checker process is not itself named `agy`; in a real deployment the gate runs as
  the operator while pool accounts are separate users, so no self-match exists.

## What was driven

| Scenario | Evidence |
| --- | --- |
| Before the fix, a done pool builder keeps agy alive and the gate stays at exit 75 | `scenario1-before-fix-pool-builder-holds-slot.log` |
| With the fix, `fm-deliver.sh run` exits it, gate returns 0, marker records the sha, worktree/endpoint preserved | `scenario1-after-fix-slot-freed.log` |
| Same sha already released: no second exit, delivery still starts | `scenario2-same-sha-no-second-exit.log` |
| Relaunched builder reports a new commit: exited again, marker updated | `scenario3-relaunched-new-sha-exited-again.log` |
| Open keyed decision under the done report: builder kept alive and key named; exit after resolve | `scenario4-open-decision-keeps-builder.log` |
| Non-pool agy ship: untouched, pane stays idle | `scenario5-non-pool-builder-untouched.log`, `scenario5-pane-non-pool-agent-still-idle.txt` |
| Real refusal (typed composer text): logged, slot stays held, delivery continues; retry after clearing the composer exits it | `scenario6-refused-exit-keeps-delivery.log`, `scenario6-retry-succeeds.log`, `scenario6-pane-after-exit-shell-remains.txt` |
| Latest lifecycle line still `working`: builder not exited | `scenario7-still-working-builder-untouched.log` |

Scenarios 1, 4 and 6 show the real agy process (`pgrep -x agy`), the real
`fm-control.sh exit` typing `/quit` into the live TUI, and the real capacity gate
flipping between 75 and 0.
