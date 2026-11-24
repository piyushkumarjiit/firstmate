# Gemini (agy) account pool setup

Gemini work runs from separate Linux accounts through the pool launcher, so the operator account needs a few one-time grants.
`bin/fm-agy-pool-setup.sh` performs every one of them in a single idempotent command.

## Commands

- `bin/fm-agy-pool-setup.sh check` is read-only and exits 1 when anything is missing.
- `bin/fm-agy-pool-setup.sh apply` does every step that needs no root and prints the exact command for each step that does.
- Run `check` before an operator-side Gemini run starts, and run `apply` again after adding a pool account.

## What it covers

- Access and default ACLs for each pool account on the no-mistakes worktrees directory, plus traverse access on its parent, so pool agents can work in run worktrees.
- A git HTTPS credential helper in each pool account, backed by the operator's `gh` login, so pushes never stop at a login prompt.
- The models allowlist (`/etc/firstmate/gpro-models.conf`): Neon and Hydrogen rules naming the pool accounts, where listed order is the quota failover order.
- Operator read access to the pool usage log and per-run logs.
- A report of the no-mistakes reviewer and fixer configuration for Gemini runs.
  This part is check-only: the script never edits the no-mistakes config.

## Limits

- Gemini cannot be a gate agent on the firstmate repository itself, because agy cannot ignore the repository's `AGENTS.md` and no-mistakes refuses it there.
- The setup script does not install or log in the pool accounts, and it does not write anything under `/etc`.

## Overrides

Paths and accounts can be redirected with `POOL_CONF`, `MODELS_CONF`, `FM_NM_WORKTREES`, `FM_NM_CONFIG`, `FM_AGY_USAGE_LOG`, `FM_AGY_STATE_DIR`, `FM_GH_CONFIG_DIR`, `FM_GH_BIN`, and `FM_SETUP_SUDO` (set to `none` to print per-account commands instead of running them).
The script header owns the exact list.
Verification lives in `tests/fm-agy-pool-setup.test.sh`.
For large review prompts see [`contrib/no-mistakes-antigravity-stdin/README.md`](../contrib/no-mistakes-antigravity-stdin/README.md).
