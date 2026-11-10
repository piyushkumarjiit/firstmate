---
name: argon-review
description: >-
  Load only when the captain explicitly asks for an Argon, Gemini, cross-model, or second-opinion review of a spec, report, or change, and when the captain returns that reviewer's findings.
user-invocable: false
metadata:
  internal: true
---

# argon-review

An optional, captain-requested cross-model review: a different model family reviews work through the captain's own web session, and the authoring worker answers every finding.
It is advisory evidence for the captain; it never blocks, replaces, or authorizes the selected delivery path, validation, or merge (`AGENTS.md` section 7).

## 1. Pack

Firstmate runs `bin/fm-argon-pack.sh` on the commit under review; its `--help` and header own the packet format, filters, secret scan, and size cap.
Prefer `--diff <base>` for a change and `--scope` for a large repo, and pass the spec or report with `--spec`.
A secret-scan refusal or a size refusal is reported to the captain as such; never rerun with `--allow-secrets` without the captain's word.
Tell the captain the packet path, commit, size, and the exact path to save the reply to: `$FM_HOME/data/argon-review/<task>-<sha12>-findings.md`.

## 2. Captain review

The captain uploads the packet as a file attachment in a fresh conversation, sends it with no extra framing, and saves the full reply verbatim to that path, or pastes it so firstmate saves it there.

## 3. Disposition

Firstmate does not judge the findings.
It sends the authoring worker (or a scout or ship when none is live) the findings path and packet path, asking for one disposition per finding id: accepted with the commit, rejected with `path:line` or test evidence, needs-captain with the question, or out-of-scope with a follow-up note.
The worker first verifies each cited location exists at the packet's commit and rejects citations that do not.
Accepted changes go through the task's normal delivery path; needs-captain rows go to `captain-hold-lifecycle`.
Firstmate relays the disposition summary to the captain.

## 4. Optional delta pass

Only when the captain asks, firstmate packs a fresh `--diff <reviewed-sha>` packet with the findings and the disposition table as `--spec`, and the captain submits it to a fresh conversation.
The reply is advisory input as in section 3.
