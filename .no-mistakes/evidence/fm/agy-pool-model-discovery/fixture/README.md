# Live fixture used for the recorded scenarios

These are the throwaway fixture scripts that produced
`../live-agy-pool-scenarios.log` against the real `bin/fm-agy-pool.sh`,
`bin/fm-agy-pool-setup.sh`, and `bin/fm-deliver.sh` from the gate worktree.

They are kept only for reproduction and are not part of the repository.
`lib.sh` hard-codes the gate worktree path and `/tmp/fm-live-agy/fx` as the
fixture root. Copy this directory to `/tmp/fm-live-agy`, then run
`bash /tmp/fm-live-agy/run_all.sh`.

Only external boundaries are faked (`agy` CLI output per account, the `sudo`
account switch, `id`, `pgrep`, and `no-mistakes` for the fm-deliver case).
The scripts under test run unmodified; every pool/state/log path points inside
the disposable fixture, which is removed at the end.
