# no-mistakes antigravity stdin patch

no-mistakes passes the whole prompt to the antigravity (`agy`) agent as one argv element.
A prompt over the Linux per-argument limit (128 KiB) therefore fails with "argument list too long" before any launcher runs.
`antigravity-stdin.patch` makes the adapter send the prompt as one NDJSON `user` event on stdin, using `--print="" --input-format stream-json --output-format stream-json`.

This patch is a local draft.
It is not published upstream, and nothing here modifies the installed no-mistakes.

## Build a locally patched no-mistakes

1. Check out the no-mistakes release matching your install (the patch is verified to apply to v1.96.0).
2. Apply it from the source root with `git apply --check /path/to/antigravity-stdin.patch`, then `git apply /path/to/antigravity-stdin.patch`.
3. Build into a separate path, for example `go build -o ~/bin/no-mistakes-stdin ./cmd/no-mistakes`, and run the Go tests for `./internal/agent/...`.
4. Point a test home at that binary instead of replacing the installed one.

## Verify with a prompt larger than 128 KiB

1. Generate a prompt of about 150 KB, for example `head -c 150000 /dev/zero | tr '\0' 'a'`, and ask the agent to reply with a fixed token.
2. Send it with the stock build and confirm the "argument list too long" failure.
3. Send the same prompt with the patched build and confirm the run completes and the reply carries the token.
4. Repeat with a `--conversation <id>` follow-up to confirm session resume still works.
