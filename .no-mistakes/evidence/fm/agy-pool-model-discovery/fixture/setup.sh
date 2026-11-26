#!/usr/bin/env bash
# Build a disposable fixture root for driving the real bin/fm-agy-pool.sh.
# Only external boundaries (agy CLI, sudo account switch, id, pgrep) are faked;
# the product under test (the pool script) runs unmodified.
set -euo pipefail
FX="${1:?fixture dir}"
rm -rf "$FX"; mkdir -p "$FX/bin" "$FX/state" "$FX/home" "$FX/catalogs"

cat > "$FX/bin/sudo" <<'EOF'
#!/usr/bin/env bash
T=""
while [ $# -gt 0 ]; do
  case "$1" in
    -n|-H|--non-interactive|--login) shift ;;
    -u) T="$2"; shift 2 ;;
    *) break ;;
  esac
done
if [ "${1:-}" = test ]; then exit 0; fi
export SUDO_TARGET_USER="$T"
export HOME="$FX_HOME/$T"
mkdir -p "$HOME"
exec "$@"
EOF

cat > "$FX/bin/id" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in -un) echo acct-a ;; -u) echo 1000 ;; *) exit 0 ;; esac
EOF

cat > "$FX/bin/fake-pgrep" <<'EOF'
#!/usr/bin/env bash
# -u <user> -x agy  -> active iff <user> is listed in $FX_ACTIVE
u=""
while [ $# -gt 0 ]; do case "$1" in -u) u="$2"; shift 2 ;; *) shift ;; esac; done
[ -f "$FX_ACTIVE" ] || exit 1
grep -Fxq -- "$u" "$FX_ACTIVE" || exit 1
exit 0
EOF

cat > "$FX/bin/agy" <<'EOF'
#!/usr/bin/env bash
acct="${SUDO_TARGET_USER:-operator}"
home="${HOME:-/nonexistent}"
printf '%s|start|%s|%s\n' "$(date +%s%3N)" "$acct" "$*" >> "$FX_CALLS"
if [ "${1:-}" = models ]; then
  echo "Fetching available models..."
  if [ -f "$home/models.txt" ]; then cat "$home/models.txt"; else exit 3; fi
  printf '%s|end|%s|%s\n' "$(date +%s%3N)" "$acct" "$*" >> "$FX_CALLS"
  exit 0
fi
if [ "${1:-}" = -p ] && [ "${2:-}" = /usage ]; then
  if [ -f "$home/usage.txt" ]; then cat "$home/usage.txt"; else exit 3; fi
  printf '%s|end|%s|%s\n' "$(date +%s%3N)" "$acct" "$*" >> "$FX_CALLS"
  exit 0
fi
printf '%s|end|%s|%s\n' "$(date +%s%3N)" "$acct" "$*" >> "$FX_CALLS"
echo "FAKE-AGY task output for $acct"
exit 0
EOF
chmod +x "$FX/bin/"*
: > "$FX/calls.log" 2>/dev/null || true
