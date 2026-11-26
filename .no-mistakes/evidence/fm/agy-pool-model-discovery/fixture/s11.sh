#!/usr/bin/env bash
set -uo pipefail
REPO=~/.no-mistakes/worktrees/406d2d249c60/01M8ARDM50Q2WJQFV62PZRT23G
FX=/tmp/fm-live-agy/setupfx
rm -rf "$FX"; mkdir -p "$FX/state" "$FX/home/state" "$FX/home/data"
printf 'acct-a\nacct-b\n' > "$FX/pool.conf"
echo "=== setup check with NO legacy gpro-models.conf present ==="
env POOL_CONF="$FX/pool.conf" MODELS_CONF="$FX/models.conf" \
  FM_AGY_STATE_DIR="$FX/state" FM_AGY_USAGE_LOG="$FX/usage.jsonl" \
  FM_HOME="$FX/home" FM_SETUP_SUDO=none FM_GH_BIN=/bin/false \
  FM_NM_WORKTREES="$FX/nm/worktrees" FM_NM_CONFIG="$FX/nm/config.yaml" \
  "$REPO/bin/fm-agy-pool-setup.sh" check 2>&1 || true
echo
echo "=== setup check with a legacy models.conf present (must report it ignored) ==="
printf '*hydrogen* acct-a\n' > "$FX/models.conf"
env POOL_CONF="$FX/pool.conf" MODELS_CONF="$FX/models.conf" \
  FM_AGY_STATE_DIR="$FX/state" FM_AGY_USAGE_LOG="$FX/usage.jsonl" \
  FM_HOME="$FX/home" FM_SETUP_SUDO=none FM_GH_BIN=/bin/false \
  FM_NM_WORKTREES="$FX/nm/worktrees" FM_NM_CONFIG="$FX/nm/config.yaml" \
  "$REPO/bin/fm-agy-pool-setup.sh" check 2>&1 | grep -E 'model|legacy|result' || true
