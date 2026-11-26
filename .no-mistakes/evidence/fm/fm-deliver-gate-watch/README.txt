Live validation - fm-deliver gate surfacing & green-PR reporting (9905a2aa)

How the lab was built
---------------------
* Disposable firstmate home: `LAB=$(mktemp -d /tmp/fm-lab.XXXXXX)` + `bin/fm-lab-home.sh create "$LAB"`.
* One real git worktree fixture per scenario under $LAB/run/<scenario>/, with
  state/<task>.meta, data/<task>/brief.md and the real append-only state/<task>.status.
* The REAL product under test is the gate worktree's bin/fm-deliver.sh. It was driven
  end-to-end (`run`, `respond --action approve`) as the main account with
  FM_DELIVER_FOREGROUND=1 against that disposable home.
* The only boundary substitute is the external `no-mistakes` CLI: a disposable
  PATH stub that speaks the documented `axi status` / `axi run` TOON contract.
  Its gate payload for s8 is the repo's byte-authentic capture
  tests/captures/no-mistakes-v1.70.1/parked.toon (only run id/branch/head substituted,
  exactly the replay contract that capture's README states).
* `base` files re-run the identical scenario against bin/fm-deliver.sh from the base
  commit a4860ac, to show the reported failure reproduces before the change.
* Nothing touched the live fleet, the default tmux/Herdr session, or the operator
  FM_HOME. The lab directory is removed after this evidence was written.
* Independent oracles: the user intent (later gates must surface; a green PR must never
  be reported blocked), the base-commit driver's observed behaviour, the repo's real
  axi-status captures (tests/captures/no-mistakes-v1.70.1/{parked,completed}.toon),
  and bin/fm-dod-lib.sh's documented drive-call contract.

Scenario map
------------
s1-*  later gates surface after a respond that exits nonzero (review -> document -> ci)
s2-*  a refused respond that leaves the run on the SAME gate keeps it open
s3-*  checks-passed + PR returned by a reattach is reported done, never blocked
s4-*  checks-passed + PR visible only in axi status is also reported done
s5-*  an older run's checks-passed line in the shared drive log is not reused
s6-*  instantly-returning reattaches are paced instead of burning the budget at once
s7-*  an open gate is never hidden behind a checks-passed outcome
s8-*  a real captured parked gate is surfaced; fleet snapshot reads it as needs-decision
lab-driver.sh  the throwaway driver that ran every scenario above
