# Gemini (agy) account pool setup

Gemini work runs from separate Linux accounts through the pool launcher, so the host needs a few one-time grants, split between one root provisioning step and one operator command.

## First-time provisioning

Run `sudo bin/fm-agy-pool-provision.sh` first.
It creates the isolated Linux pool users listed in `/etc/firstmate/gpro-pool.conf` ([example](examples/gpro-pool.conf.example)), the shared group, the system `agy` copy, the ACLs, and the sudoers rule.
Its header owns the full setup order, the environment variables, adding or removing an account, and how to undo.

## Commands

- `bin/fm-agy-pool-setup.sh check` is read-only and exits 1 when anything is missing.
- `bin/fm-agy-pool-setup.sh apply` does every step that needs no root and prints the exact command for each step that does.
- Run `check` before an operator-side Gemini run starts, and run `apply` again after adding a pool account.

## What it covers

- Access and default ACLs for each pool account on the no-mistakes worktrees directory, plus traverse access on its parent, so pool agents can work in run worktrees.
- Traverse access from each pool account into this home's `state/` and `data/`, and access plus default ACLs on every clone under `projects/`, so any task shape can record status, read its steering inbox, and commit.
- A git HTTPS credential helper in each pool account, backed by the operator's `gh` login, so a pool account's own clone or fetch of a private origin never stops at a login prompt.
- The operator account's own push credentials (check only): a working `gh` login and a git credential helper, because `fm-deliver` runs no-mistakes, and so the push, as the operator. A failed push reports a blocker naming these `operator push credentials` check lines.
- The models allowlist (`/etc/firstmate/gpro-models.conf`): Neon and Hydrogen rules naming the pool accounts, where listed order is the quota failover order.
- Operator read access to the pool usage log and per-run logs.
- A report of the no-mistakes reviewer and fixer configuration for Gemini runs, including whether `agent_path_override.antigravity` points at `bin/agy-pool/nm-agy`.
  That file is edited by hand; this step is check-only and the script never writes the no-mistakes config.

## What changes with a pool configured

The pool takes over on a home whose pool config lists at least one account, for every firstmate-launched `agy` crew ship or scout (`no-mistakes`, `direct-PR`, `local-only`, and scouts); a secondmate (which keeps the plain `agy` launcher and runs as the operator, and for which `--account` is refused), a raw launch command, and every non-agy harness keep their existing launch.
Only the `no-mistakes` ship needs the pool-builder brief below; the other shapes keep their ordinary brief and delivery contract.
Name the account for one task with `--account <pool account>` on `bin/fm-spawn.sh` (a Linux account name from the pool config, never a Google address).
The spawn checks it through `bin/agy-pool/agy --check-account <account> [model]` before any pane exists: it must be listed, exist, be signed in, be allowed for the model by the models config, and not be marked exhausted, or the spawn refuses and never picks another account.
It is recorded as `account=` in the task record, handed to the launcher as `FM_AGY_USER`, and reused on relaunch unless a new `--account` moves it; without `--account` the automatic choice applies.
The launcher grants the selected account an ACL on that task's `data/<task>/` only (a scout's `report.md`), and `bin/fm-agy-pool-setup.sh` checks and applies traverse access on `state/` and `data/` (step `task-paths`).
Pool-routed scouts and ships use the pool account's quota, not the operator's own agy sign-in, and their commits are authored by the pool worker identity (`Firstmate Worker (<account>)`), not the operator.
Before a spawn creates any pane, `bin/agy-pool/agy --check-capacity [account]` (read-only, no pool state written) refuses a launch beyond `FM_AGY_MAX_ACTIVE` with exit 75, so the task stays queued.
Every pool-launched ship or scout worker, direct-PR and local-only included, is stopped by `bin/fm-pool-exit.sh` once its latest status is `done` (a scout counts only once `data/<task>/report.md` exists), which frees its slot; unlike other harnesses, an agy direct-PR worker therefore cannot be steered after `done` until `bin/fm-control.sh <task> relaunch` brings it back (on its recorded account, with the pool capacity checked before the old agent stops when the old agent was not an agy one). A secondmate is not routed through the pool.
Run `bin/fm-agy-pool-setup.sh apply` after adding a project: step `projects` gives each pool account write access to every clone under `projects/` so a pool worker can commit there; `check` reports what is missing.
Direct-PR and local-only workers push through the pool account's git credential helper and open pull requests through the operator's `gh` login, whose config directory the launcher forwards read-only to those interactive ship workers only (never to scouts, builders, or no-mistakes review and fix calls).

- Scaffold a `no-mistakes` ship with `bin/fm-brief.sh --pool-build`, and `bin/fm-spawn.sh` refuses a spawn whose brief and launcher disagree.
  The worker builds, commits on its task branch, and reports `done: committed <sha>` without running no-mistakes, pushing, or opening a PR.
- Firstmate then drives validation through `bin/fm-deliver.sh`, which runs as the operator account, so delivery's push and pull request use the operator's own git credential and `gh` login rather than a pool account's.
- Review and fix models come from the `roles` lists in `config/crew-dispatch.json` ([schema](configuration.md#crew-dispatch-profiles-configcrew-dispatchjson)).
- At most `FM_AGY_MAX_ACTIVE` pool accounts (default 2) run at once; a call over that cap exits 75, which `bin/fm-deliver.sh` reports as a blocker instead of restarting the run.
- On Herdr, each review and fix call opens a read-only `review: <task> (<model>)` or `fix: <task> (<model>)` tab, and delivery opens a `deliver: <task>` tab, so the agent runs under the pool accounts are visible in the task's workspace.

## Limits

- Gemini cannot be a gate agent on the firstmate repository itself, because agy cannot ignore the repository's `AGENTS.md` and no-mistakes refuses it there.
- The setup script does not install or log in the pool accounts, and it does not write anything under `/etc`; the provisioner creates the accounts, and each one still needs its own interactive `agy` sign-in.

## Overrides

Paths and accounts can be redirected with `POOL_CONF`, `MODELS_CONF`, `FM_NM_WORKTREES`, `FM_NM_CONFIG`, `FM_AGY_USAGE_LOG`, `FM_AGY_STATE_DIR`, `FM_HOME`, `FM_STATE_OVERRIDE`, `FM_DATA_OVERRIDE`, `FM_PROJECTS_OVERRIDE`, `FM_GH_CONFIG_DIR`, `FM_GH_BIN`, and `FM_SETUP_SUDO` (set to `none` to print per-account commands instead of running them).
The script header owns the exact list.
Verification lives in `tests/fm-agy-pool-setup.test.sh` and `tests/fm-agy-pool-provision.test.sh`.
For large review prompts see [`contrib/no-mistakes-antigravity-stdin/README.md`](../contrib/no-mistakes-antigravity-stdin/README.md).
