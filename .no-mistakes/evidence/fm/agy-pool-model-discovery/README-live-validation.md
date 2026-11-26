# Live validation: per-account model discovery, Neon reservation, start/end quota readings

Branch `fm/agy-pool-model-discovery` at `fc06db05`.

All scenarios drive the real `bin/agy-pool/agy` launcher (the script firstmate
runs for a pool task) in a disposable state dir, usage log and `FM_HOME`, never
the operator's `/tmp/fm-agy-pool`, `/var/log/firstmate/agy-usage.jsonl` or a real
pool account.

Two isolation levels were used:

* **real** - the launcher runs the machine's own `agy` under `sudo -u agentic`
  for the operator's own signed-in account, so catalog discovery, the live
  `/usage` reading, the prompt and the JSONL log are all real. (`scenario23*`.)
* **fixture accounts** - the launcher, its lock, selection, state files and log
  are still the real product; only the un-mintable boundary (several separate
  signed-in Google accounts) is faked with a sudo/id/pgrep shim and a stub `agy`
  that answers `models` and `-p /usage` for a named account.
  (`scenario4*`, `scenario5*`, `scenario6*`.)

## Scenarios

| Artifact | What it shows |
| --- | --- |
| `scenario23-transcript.txt` | Real account: first use discovers the account's catalog from live `agy models`; a Hydrogen task launches and answers; a Neon request is refused (exit 75) even with a legacy `*neon* agentic` map; a fresh catalog is reused with no re-fetch; a stale catalog (TTL=1s) is refreshed; every launched task logs a start and an end reading. The `--check-model` / `--check-account` spawn gates allow with an "unknown" notice on no catalog, refuse an unlisted model on a fresh catalog, and stay read-only. |
| `scenario4-transcript.txt` | Last-active account is tried first (even against a higher saved reading); when it cannot serve the model the fallback follows the last saved quota reading (85 before 45) rather than config order; the at-cap active-account branch and an already-active explicit account both take one live `/usage` of that same account, print it, and log it as a `usage_check` start reading. |
| `scenario5-transcript.txt` | An account whose own catalog lists Neon is reserved: Flash and Hydrogen work goes to the non-Neon account even though the Neon account is listed first with a higher reading and the legacy `*neon*` map names the other account; only when the non-Neon account is exhausted does Flash spill over; a Neon model goes to the Neon account. `--status` reports the discovered `reserved (neon)` / `standard` tier. |
| `scenario6-transcript.txt`, `scenario6-gate-intervals.tsv` | Two concurrent launches on different accounts never overlap their live queries and are spaced by `FM_AGY_PACING_SEC` (3s configured, 3063ms observed); a same-account query is not gapped (301ms under `PACING_SEC=30`); a different-account query waits (5331ms under `PACING_SEC=5`); a live `/usage` on a third account is refused while two accounts are active. |
| `setup-check-*.txt` | `bin/fm-agy-pool-setup.sh check` no longer needs a models allowlist: the models step passes without any `gpro-models.conf`, and a legacy file present is reported as ignored. (The other MISSING lines come from running inside the gate worktree instead of the operator home and are unrelated to this change.) |
| `fixture.sh`, `scenario*.sh` | The disposable drivers used above, for reproduction. |

The scripts live only in this evidence directory and in `/tmp`; no source file
was changed for testing.
