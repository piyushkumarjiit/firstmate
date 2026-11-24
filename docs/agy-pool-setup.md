# Gemini (agy) account pool setup

Gemini work runs from separate Linux accounts through the pool launcher, so the operator account needs a few one-time grants.
`bin/fm-agy-pool-setup.sh` performs every one of them in a single idempotent command.

## Commands

- `bin/fm-agy-pool-setup.sh check` is read-only and exits 1 when anything is missing.
- `bin/fm-agy-pool-setup.sh apply` does every step that needs no root and prints the exact command for each step that does.
- Run `check` before an operator-side Gemini run starts, and run `apply` again after adding a pool account.

## What it covers

- Access and default ACLs for each pool account on the no-mistakes worktrees directory, plus traverse access on its parent, so pool agents can work in run worktrees.
- A git HTTPS credential helper in each pool account, backed by the operator's `gh` login, so a pool account's own clone or fetch of a private origin never stops at a login prompt.
- The models allowlist (`/etc/firstmate/gpro-models.conf`): Neon and Hydrogen rules naming the pool accounts, where listed order is the quota failover order.
- Operator read access to the pool usage log and per-run logs.
- A report of the no-mistakes reviewer and fixer configuration for Gemini runs, including whether `agent_path_override.antigravity` points at `bin/agy-pool/nm-agy`.
  That file is edited by hand; this step is check-only and the script never writes the no-mistakes config.

## What changes with a pool configured

The pool takes over only on a home whose pool config lists at least one account, and only for `agy` ships in `no-mistakes` mode; every other agy launch keeps the plain binary.

- Scaffold such a ship with `bin/fm-brief.sh --pool-build`, and `bin/fm-spawn.sh` refuses a spawn whose brief and launcher disagree.
  The worker builds, commits on its task branch, and reports `done: committed <sha>` without running no-mistakes, pushing, or opening a PR.
- Firstmate then drives validation through `bin/fm-deliver.sh`, which runs as the operator account, so delivery's push and pull request use the operator's own git credential and `gh` login rather than a pool account's.
- Review and fix models come from the `roles` lists in `config/crew-dispatch.json` ([schema](configuration.md#crew-dispatch-profiles-configcrew-dispatchjson)).
- At most `FM_AGY_MAX_ACTIVE` pool accounts (default 2) run at once; a call over that cap exits 75, which `bin/fm-deliver.sh` reports as a blocker instead of restarting the run.
- On Herdr, each review and fix call opens a read-only `review: <task> (<model>)` or `fix: <task> (<model>)` tab, and delivery opens a `deliver: <task>` tab, so the agent runs under the pool accounts are visible in the task's workspace.

## Limits

- Gemini cannot be a gate agent on the firstmate repository itself, because agy cannot ignore the repository's `AGENTS.md` and no-mistakes refuses it there.
- The setup script does not install or log in the pool accounts, and it does not write anything under `/etc`.

## Overrides

Paths and accounts can be redirected with `POOL_CONF`, `MODELS_CONF`, `FM_NM_WORKTREES`, `FM_NM_CONFIG`, `FM_AGY_USAGE_LOG`, `FM_AGY_STATE_DIR`, `FM_GH_CONFIG_DIR`, `FM_GH_BIN`, and `FM_SETUP_SUDO` (set to `none` to print per-account commands instead of running them).
The script header owns the exact list.
Verification lives in `tests/fm-agy-pool-setup.test.sh`.
For large review prompts see [`contrib/no-mistakes-antigravity-stdin/README.md`](../contrib/no-mistakes-antigravity-stdin/README.md).
