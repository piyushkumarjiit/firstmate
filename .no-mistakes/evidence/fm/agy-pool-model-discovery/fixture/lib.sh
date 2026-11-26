#!/usr/bin/env bash
set -uo pipefail
REPO=~/.no-mistakes/worktrees/406d2d249c60/01M8ARDM50Q2WJQFV62PZRT23G
POOL="$REPO/bin/fm-agy-pool.sh"
FX=${FX:-/tmp/fm-live-agy/fx}

mkuser() { # <acct> <models...>
  local a=$1; shift
  mkdir -p "$FX/home/$a"
  : > "$FX/home/$a/models.txt"
  local m
  for m in "$@"; do printf '%s\t%s\n' "$m" "$m" >> "$FX/home/$a/models.txt"; done
}
usage() { # <acct> <pct> [reset]
  local a=$1 p=$2 r=${3:-2027-01-01T00:00:00Z}
  mkdir -p "$FX/home/$a"
  {
    printf 'Gemini Models\tWeekly Limit Remaining\t%s%%\t%s\n' "$p" "$r"
    printf 'Gemini Models\tFive Hour Limit Remaining\t%s%%\t%s\n' "$(( p + 1 ))" "$r"
  } > "$FX/home/$a/usage.txt"
}
catalog() { # <acct> <fetched_at> <models...>
  local a=$1 ts=$2; shift 2
  local json
  json=$(printf '%s\n' "$@" | jq -R . | jq -sc --arg u "$a" --argjson t "$ts" '{user:$u,fetched_at:$t,models:.}')
  printf '%s\n' "$json" > "$FX/state/$a.models.json"
}
poolconf() { printf '%s\n' "$@" > "$FX/pool.conf"; }
reset_fixture() {
  rm -rf "$FX/state" "$FX/home" "$FX/usage.jsonl" "$FX/calls.log"
  mkdir -p "$FX/state" "$FX/home"
  : > "$FX/calls.log"
  : > "$FX/active"
  : > "$FX/models.conf"
}
runpool() { # <env...> -- <args...>
  local -a envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  env -u FM_AGY_USER -u FM_AGY_POOL_MODEL \
    PATH="$FX/bin:$PATH" POOL_CONF="$FX/pool.conf" MODELS_CONF="$FX/models.conf" \
    AGY_BIN="$FX/bin/agy" FM_AGY_STATE_DIR="$FX/state" FM_AGY_USAGE_LOG="$FX/usage.jsonl" \
    FM_AGY_PGREP="$FX/bin/fake-pgrep" FX_CALLS="$FX/calls.log" FX_ACTIVE="$FX/active" \
    FX_HOME="$FX/home" FM_AGY_PACING_SEC=0 \
    ${envs[@]+"${envs[@]}"} \
    "$POOL" "$@" </dev/null 2>&1
}
now=$(date +%s)
