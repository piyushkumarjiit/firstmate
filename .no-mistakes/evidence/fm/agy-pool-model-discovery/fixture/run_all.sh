#!/usr/bin/env bash
# Drive the real bin/fm-agy-pool.sh and bin/fm-agy-pool-setup.sh end-to-end in a
# disposable fixture. Only the external boundaries are faked: the agy CLI
# (models//usage output per account), the sudo account switch, id, and pgrep.
# The product scripts under test run unmodified from the gate worktree.
set -uo pipefail
echo "# live agy-pool validation"
echo "# date: $(date -Is)"
echo "# worktree: $(cd ~/.no-mistakes/worktrees/406d2d249c60/01M8ARDM50Q2WJQFV62PZRT23G && git rev-parse --short HEAD)"
echo "# fixture: /tmp/fm-live-agy/fx (disposable; faked agy CLI, sudo switch, id, pgrep)"
bash /tmp/fm-live-agy/setup.sh /tmp/fm-live-agy/fx >/dev/null
for s in s1 s2 s3 s4 s5 s6 s6b s7 s7b s7d s8 s9 s10 s11 s12; do
  echo
  echo "################ $s ################"
  bash "/tmp/fm-live-agy/$s.sh" 2>&1
  echo "[exit of scenario runner: $?]"
done
echo
echo "# teardown"
bash /tmp/fm-live-agy/setup.sh /tmp/fm-live-agy/fx >/dev/null 2>&1
rm -rf /tmp/fm-live-agy/fx /tmp/fm-live-agy/setupfx
echo "# fixture removed; real /tmp/fm-agy-pool and /etc/firstmate state untouched"
