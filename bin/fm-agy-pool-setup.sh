#!/usr/bin/env bash
# One idempotent setup for running Gemini (agy) work through the account pool.
#
# Usage: bin/fm-agy-pool-setup.sh [apply|check] [--help]
#   check  (default) read-only: report every missing or wrong item, exit 1 if any.
#   apply  perform every step that needs no root, and print the exact command
#          for each step that does. Re-running changes nothing already correct.
#
# Steps, in order:
#   1. acl       pool accounts get rwX plus default ACLs on the no-mistakes
#                worktrees directory, so a pool agent can read and write the
#                operator-side run worktrees.
#   2. git-auth  each pool account gets a git HTTPS credential helper backed by
#                the operator's gh login (read-only ACL on the gh config dir),
#                so a pool account's own clone or fetch never hits a login
#                prompt; the push is bin/fm-deliver.sh's, and it uses the
#                operator's own git credential and gh login instead.
#   3. models    the models allowlist maps Neon and Hydrogen models to accounts;
#                its account order is the quota failover order.
#   4. run-log   the operator can read the pool usage log and per-run logs.
#   5. nm-config reports the no-mistakes reviewer/fixer configuration for
#                Gemini runs. Check only: the operator config is never edited.
#
# Environment overrides (tests and non-default homes):
#   POOL_CONF, MODELS_CONF          pool account list and model allowlist
#   FM_NM_WORKTREES                 default $NM_HOME or ~/.no-mistakes, + /worktrees
#   FM_NM_CONFIG                    default $NM_HOME or ~/.no-mistakes, + /config.yaml
#   FM_AGY_USAGE_LOG, FM_AGY_STATE_DIR   pool run-log locations
#   FM_GH_CONFIG_DIR, FM_GH_BIN     operator gh config dir and binary
#   FM_SETUP_SUDO                   privilege prefix for per-account commands
#                                   (default "sudo -n"); "none" disables them
#                                   and prints the command instead
set -uo pipefail

MODE=check
case "${1:-}" in
  ""|check) MODE=check ;;
  apply) MODE=apply ;;
  -h|--help|help) sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "usage: fm-agy-pool-setup.sh [apply|check]" >&2; exit 2 ;;
esac

POOL_CONF="${POOL_CONF:-/etc/firstmate/gpro-pool.conf}"
MODELS_CONF="${MODELS_CONF:-/etc/firstmate/gpro-models.conf}"
NM_BASE="${NM_HOME:-$HOME/.no-mistakes}"
NM_WORKTREES="${FM_NM_WORKTREES:-$NM_BASE/worktrees}"
NM_CONFIG="${FM_NM_CONFIG:-$NM_BASE/config.yaml}"
USAGE_LOG="${FM_AGY_USAGE_LOG:-/var/log/firstmate/agy-usage.jsonl}"
STATE_DIR="${FM_AGY_STATE_DIR:-/tmp/fm-agy-pool}"
GH_CONFIG_DIR="${FM_GH_CONFIG_DIR:-${GH_CONFIG_DIR:-$HOME/.config/gh}}"
GH_BIN="${FM_GH_BIN:-$(command -v gh 2>/dev/null || echo gh)}"
SUDO_PREFIX="${FM_SETUP_SUDO:-sudo -n}"
OPERATOR=$(id -un)

PROBLEMS=0
ok() { printf 'ok      %s\n' "$*"; }
miss() { PROBLEMS=$((PROBLEMS + 1)); printf 'MISSING %s\n' "$*"; }
fixed() { printf 'fixed   %s\n' "$*"; }
need_root() { PROBLEMS=$((PROBLEMS + 1)); printf 'ROOT    %s\n        run: %s\n' "$1" "$2"; }

mapfile -t POOL_USERS < <(grep -Ev '^\s*(#|$)' "$POOL_CONF" 2>/dev/null | awk '{print $1}')

run_as() { # <user> <cmd...>; returns 127 when per-account commands are disabled
  local user=$1; shift
  [[ "$SUDO_PREFIX" != none ]] || return 127
  # shellcheck disable=SC2086
  $SUDO_PREFIX -u "$user" "$@"
}

has_acl() { # <path> <acl-line-regex> : does getfacl list it
  getfacl -p "$1" 2>/dev/null | grep -Eq "$2"
}

check_reach() { # <user> <path> <test-flag> <label>: effective access as the pool account
  local u=$1 target=$2 flag=$3 label=$4 d blocked="" rc
  run_as "$u" test "$flag" "$target"; rc=$?
  [[ $rc -eq 127 ]] && return 0
  if [[ $rc -eq 0 ]]; then
    ok "$label reachable by $u"
    return 0
  fi
  d=$(dirname "$target")
  while [[ "$d" != "/" && "$d" != "." ]]; do
    run_as "$u" test -x "$d" || blocked="$blocked '$d'"
    d=$(dirname "$d")
  done
  if [[ -n "$blocked" ]]; then
    need_root "$u cannot traverse to $label" "sudo setfacl -m u:${u}:--x$blocked"
  else
    miss "$label not reachable by $u"
  fi
}

# --- 1. worktree ACLs -------------------------------------------------------
step_acl() {
  local u
  if [[ ! -d "$NM_WORKTREES" ]]; then
    if [[ $MODE == apply ]]; then
      mkdir -p "$NM_WORKTREES" && fixed "created $NM_WORKTREES"
    else
      miss "worktrees directory $NM_WORKTREES does not exist"
      return
    fi
  fi
  command -v setfacl >/dev/null 2>&1 || { miss "setfacl not installed (acl package)"; return; }
  for u in "${POOL_USERS[@]}"; do
    id "$u" >/dev/null 2>&1 || { miss "pool account '$u' does not exist"; continue; }
    if has_acl "$NM_WORKTREES" "^user:${u}:rwx" && has_acl "$NM_WORKTREES" "^default:user:${u}:rwx"; then
      ok "ACL (access + default) for $u on $NM_WORKTREES"
    elif [[ $MODE == apply ]]; then
      if setfacl -R -m "u:${u}:rwX" -m "d:u:${u}:rwX" "$NM_WORKTREES" 2>/dev/null; then
        fixed "ACL (access + default) for $u on $NM_WORKTREES"
      else
        need_root "cannot set ACL for $u on $NM_WORKTREES" "sudo setfacl -R -m u:${u}:rwX -m d:u:${u}:rwX '$NM_WORKTREES'"
      fi
    else
      miss "ACL (access + default) for $u on $NM_WORKTREES"
    fi
  done
  # Pool accounts must traverse the no-mistakes base directory to reach worktrees.
  for u in "${POOL_USERS[@]}"; do
    id "$u" >/dev/null 2>&1 || continue
    local base; base=$(dirname "$NM_WORKTREES")
    if has_acl "$base" "^user:${u}:..x"; then
      ok "traverse ACL for $u on $base"
    elif [[ $MODE == apply ]]; then
      if setfacl -m "u:${u}:--x" "$base" 2>/dev/null; then
        fixed "traverse ACL for $u on $base"
      else
        need_root "cannot set traverse ACL for $u on $base" "sudo setfacl -m u:${u}:--x '$base'"
      fi
    else
      miss "traverse ACL for $u on $base"
    fi
    check_reach "$u" "$NM_WORKTREES" -x "worktrees directory $NM_WORKTREES"
  done
}

# --- 2. git HTTPS credentials via the operator's gh login ----------------------
CRED_KEY="credential.https://github.com.helper"
cred_helper_value() { printf '!GH_CONFIG_DIR=%s %s auth git-credential' "$GH_CONFIG_DIR" "$GH_BIN"; }

step_git_auth() {
  local u want
  want=$(cred_helper_value)
  if [[ ! -d "$GH_CONFIG_DIR" ]]; then
    miss "operator gh config dir $GH_CONFIG_DIR not found (run: gh auth login)"
    return
  fi
  for u in "${POOL_USERS[@]}"; do
    id "$u" >/dev/null 2>&1 || continue
    if has_acl "$GH_CONFIG_DIR" "^user:${u}:r.x"; then
      ok "gh config readable by $u"
    elif [[ $MODE == apply ]]; then
      if setfacl -R -m "u:${u}:rX" "$GH_CONFIG_DIR" 2>/dev/null; then
        fixed "gh config readable by $u"
      else
        need_root "cannot grant $u read access to $GH_CONFIG_DIR" "sudo setfacl -R -m u:${u}:rX '$GH_CONFIG_DIR'"
      fi
    else
      miss "gh config readable by $u"
    fi
    [[ ! -f "$GH_CONFIG_DIR/hosts.yml" ]] || check_reach "$u" "$GH_CONFIG_DIR/hosts.yml" -r "gh credentials $GH_CONFIG_DIR/hosts.yml"
    local have rc
    have=$(run_as "$u" git config --global --get-all "$CRED_KEY" 2>/dev/null); rc=$?
    if [[ $rc -eq 0 ]] && grep -Fxq "$want" <<<"$have"; then
      ok "git HTTPS credential helper for $u"
    elif [[ $MODE == apply ]]; then
      if run_as "$u" git config --global --replace-all "$CRED_KEY" "$want" 2>/dev/null; then
        fixed "git HTTPS credential helper for $u"
      else
        need_root "cannot configure git credentials for $u" "sudo -u $u git config --global --replace-all '$CRED_KEY' '$want'"
      fi
    elif [[ $rc -eq 127 ]]; then
      miss "git HTTPS credential helper for $u (cannot inspect without sudo; apply prints the command)"
    else
      miss "git HTTPS credential helper for $u"
    fi
  done
}

# --- 3. models allowlist --------------------------------------------------------
step_models() {
  local u pat
  if [[ ! -f "$MODELS_CONF" ]]; then
    need_root "models allowlist $MODELS_CONF is missing" \
      "sudo install -D -m 0644 /dev/stdin '$MODELS_CONF' <<'EOF'
*hydrogen* ${POOL_USERS[*]// /,}
*neon* ${POOL_USERS[*]// /,}
EOF"
    return
  fi
  for pat in '*neon*' '*hydrogen*'; do
    local line
    line=$(grep -Ev '^\s*(#|$)' "$MODELS_CONF" | awk -v p="$pat" '$1 == p {print; exit}')
    if [[ -z "$line" ]]; then
      need_root "no '$pat' rule in $MODELS_CONF" "echo '$pat ${POOL_USERS[*]}' | sudo tee -a '$MODELS_CONF'  # list accounts comma-separated, first is tried first"
      continue
    fi
    local accts; accts=$(awk '{$1=""; print}' <<<"$line" | tr ',' ' ')
    local listed=0
    for u in "${POOL_USERS[@]}"; do
      grep -Eqw -- "$u" <<<"$accts" && listed=$((listed + 1))
    done
    if (( listed == 0 )); then
      miss "'$pat' rule in $MODELS_CONF names no pool account"
    else
      ok "'$pat' -> ${accts# } (order is the quota failover order)"
    fi
  done
  (( ${#POOL_USERS[@]} > 0 )) || miss "no pool accounts in $POOL_CONF"
}

# --- 4. run-log readability for the operator -------------------------------------------
step_run_log() {
  if [[ -e "$USAGE_LOG" ]]; then
    if [[ -r "$USAGE_LOG" ]]; then ok "usage log readable: $USAGE_LOG"
    else need_root "usage log not readable by $OPERATOR" "sudo setfacl -m u:${OPERATOR}:r '$USAGE_LOG'"; fi
  elif [[ -d "$(dirname "$USAGE_LOG")" ]]; then
    ok "usage log not created yet (pool writes it on first run)"
  else
    need_root "usage log directory $(dirname "$USAGE_LOG") missing" "sudo install -d -m 1777 '$(dirname "$USAGE_LOG")'"
  fi
  if [[ -d "$STATE_DIR" ]]; then
    if [[ -r "$STATE_DIR" && -x "$STATE_DIR" ]]; then ok "pool state readable: $STATE_DIR"
    else miss "pool state dir $STATE_DIR not readable by $OPERATOR"; fi
  elif [[ $MODE == apply ]]; then
    mkdir -p "$STATE_DIR" && chmod 1777 "$STATE_DIR" 2>/dev/null && fixed "created $STATE_DIR"
  else
    ok "pool state dir not created yet (pool creates it on first run)"
  fi
  # Per-run logs live in task data dirs the pool account writes; the pool chmods them 0644.
  local f bad=0
  for f in /tmp/fm-agy-run.*; do
    [[ -e "$f" ]] || continue
    [[ -r "$f" ]] || bad=$((bad + 1))
  done
  if (( bad > 0 )); then miss "$bad pool run log(s) under /tmp not readable by $OPERATOR"; else ok "pool run logs readable"; fi
}

# --- 5. no-mistakes reviewer/fixer configuration (check only) --------------------------------
step_nm_config() {
  if [[ ! -f "$NM_CONFIG" ]]; then
    miss "no-mistakes config $NM_CONFIG not found"
    return
  fi
  local nm_agy_hint="<firstmate>/bin/agy-pool/nm-agy"
  if grep -Eq '^agent_path_override:' "$NM_CONFIG" && grep -Eq '^[[:space:]]+antigravity:[[:space:]]*[^[:space:]]*nm-agy' "$NM_CONFIG"; then
    ok "antigravity launcher points at nm-agy"
  else
    miss "agent_path_override.antigravity should point at $nm_agy_hint (edit $NM_CONFIG by hand; this script never does)"
  fi
  if awk '/^review_agents:/{f=1;next} /^[^ #]/{f=0} f' "$NM_CONFIG" | grep -Eq 'agent:[[:space:]]*antigravity'; then
    ok "review_agents use antigravity"
    echo "        note: nm-agy picks review/fix models from the per-task role record, not from this file"
  else
    echo "info    review_agents do not use antigravity; Gemini review/fix is not active in $NM_CONFIG"
  fi
  if grep -Eq '^agent_args_override:' "$NM_CONFIG" && grep -Eq '^[[:space:]]+antigravity:.*--(model|account)' "$NM_CONFIG"; then
    echo "info    agent_args_override.antigravity pins --model/--account; nm-agy replaces them from firstmate roles when a role record exists"
  fi
  echo "info    firstmate's own repo sets disable_project_settings, which no-mistakes refuses for antigravity gate agents: keep Gemini gates off the firstmate repo"
}

echo "fm-agy-pool-setup: mode=$MODE operator=$OPERATOR pool=${POOL_USERS[*]:-<none>}"
step_acl
step_git_auth
step_models
step_run_log
step_nm_config

if (( PROBLEMS > 0 )); then
  echo "result: $PROBLEMS item(s) need attention"
  exit 1
fi
echo "result: all checks passed"
exit 0
