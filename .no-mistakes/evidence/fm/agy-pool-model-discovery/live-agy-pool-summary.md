# Live validation: fm-agy-pool model discovery, pacing, and start/end quota logs

Change under test: `fm/agy-pool-model-discovery` at `c1941fa8` (worktree
`~/.no-mistakes/worktrees/406d2d249c60/01M8ARDM50Q2WJQFV62PZRT23G`).

## How it was driven

The real `bin/fm-agy-pool.sh` (and `bin/fm-agy-pool-setup.sh`) ran unmodified
from the gate worktree, once per scenario, against a disposable fixture:

* `POOL_CONF`, `FM_AGY_STATE_DIR`, `FM_AGY_USAGE_LOG` all pointed inside the
  throwaway fixture directory (removed at the end of the run).
* Only the external boundaries were faked: the `agy` CLI (per-account
  `models` / `-p /usage` output, plus a task-run marker), the `sudo` account
  switch (runs the command with `HOME=<fixture>/home/<account>`), `id`, and
  `pgrep`.
* No real pool account, no real `agy` login, no `/etc/firstmate` config, and no
  real `/tmp/fm-agy-pool` state was touched. `flock`, `jq`, `timeout` and the
  whole routing/logging path are the real ones.

Transcript of every scenario: `live-agy-pool-scenarios.log`, with the fixture
scripts kept in `fixture/` for reproduction.

## What each scenario proved

| scenario | observed |
|---|---|
| last-active account supports the model | routed to the last-active account, one live `/usage` start read (72%), `quota_end` recorded after the task, run summary appended |
| per-account model discovery, legacy map ignored | legacy `gpro-models.conf` said Hydrogen lives on `acct-b`; only `acct-c`'s catalog listed it, so the pool refreshed `acct-c`'s stale catalog with a single live `agy models` (other catalogs untouched) and routed to `acct-c` |
| fallback order by last saved quota | no last-active record, saved readings 30/80/50 -> routed to the 80% account without querying the others |
| live floor skip | last-active account read 8% live (floor 15) -> skipped, marked exhausted with the stated reset, routed to the 65% account |
| Neon reservation | Flash and Hydrogen run on the non-Neon account (40%) while the only Neon-capable account had 95%; a Neon model used the Neon account |
| machine-wide pacing (adversarial) | 3 concurrent launches on 3 different accounts: every `agy models` and `/usage` query serialized under one `flock`, no overlap, consecutive different-account queries >= PACING apart; same-account back-to-back queries not gapped (0.4-0.5s) |
| at-cap reuse start reading | 2 active accounts, saved 45/90 -> reused the higher one, printed its live 87% (not 100), logged `usage_check` decision `start` |
| at-cap model fit | Neon request reused the only Neon-capable active account (40%) rather than the richer one (95%); a model no active account serves exited 75 instead of substituting |
| explicit already-active user | `--user acct-a` while active: live 66% start reading recorded and printed |
| no live read -> unknown | `/usage` failed: route line prints `unknown remaining`, log decision `unknown` (no 100% estimate) |
| spawn gates (what `bin/fm-spawn.sh` calls) | `--check-model` refuses a model absent from every fresh catalog, allows listed and unknown catalogs with a notice; `--check-account` refuses per-account; zero live `agy` invocations and no state writes during the gates |
| setup `models` step | `bin/fm-agy-pool-setup.sh check` reports catalog-based discovery as ok with no legacy `gpro-models.conf`, and reports the legacy file as present-and-ignored when it exists |
| delivery role failover (fm-deliver) | with the only account whose fresh catalog lists the review model exhausted, the deliver run starts on the next role model; when a healthy non-exhausted account also lists it in a fresh catalog, the run starts on the first model and a non-quota failure does not fail over |
