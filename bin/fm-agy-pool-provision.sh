#!/usr/bin/env bash
# Root provisioner for the Gemini (agy) account pool: creates the isolated Linux
# pool users, the shared group, a system-wide agy copy, ACLs, and the sudoers rule.
#
# Usage: sudo bin/fm-agy-pool-provision.sh [--help]
#   Must run as root (via sudo). Idempotent: re-running changes nothing already
#   correct, and it is the same command to run again after adding an account.
#
# WHAT THE POOL IS
#   One Linux user per Google AI Pro account, so each account's agy sign-in
#   (OAuth token in ~/.gemini/antigravity-cli/) and its model quota stay isolated
#   from every other account and from the operator. Firstmate's pool launcher
#   (bin/fm-agy-pool.sh) picks a pool user per Gemini call and runs agy as that
#   user through passwordless sudo, which step 4 below grants. This script is the
#   only root-needing part; bin/fm-agy-pool-setup.sh does everything else.
#
# FULL SETUP ORDER (one-time, then per added account)
#   1. Edit /etc/firstmate/gpro-pool.conf: one pool username per line, "#" comments
#      and blank lines ignored (example: docs/examples/gpro-pool.conf.example).
#      If the file is missing, this script creates it with the placeholders
#      gpro1 and gpro2; replace them with your real account names.
#   2. sudo bin/fm-agy-pool-provision.sh        (this script, as root)
#   3. bin/fm-agy-pool-setup.sh apply, then bin/fm-agy-pool-setup.sh check
#      (as the operator; non-root ACLs, git auth, models allowlist, run logs).
#   4. Sign in once per pool account: sudo -H -u <poolUser> agy, and complete the
#      Google login for that account. This script reports who is still pending.
#      Model availability and Neon reservation are discovered dynamically per
#      account via `agy models`; legacy /etc/firstmate/gpro-models.conf is not needed.
#
# ENVIRONMENT VARIABLES READ (all optional)
#   POOL_CONF       pool account list         (default /etc/firstmate/gpro-pool.conf)
#   PRIMARY_USER    operator account that runs firstmate; gets the sudoers rule
#                   (default: the sudo-invoking user, SUDO_USER)
#   SHARED_GROUP    group shared by operator and pool users   (default agents)
#   SOURCE_AGY_BIN  operator's own agy binary to copy
#                   (default <PRIMARY_USER home>/.local/bin/agy)
#   AGY_BIN         system-wide copy that pool users execute  (default /usr/local/bin/agy)
#   REPO_PATHS      space-separated directories pool users must read and write
#                   (default: <home>/firstmate, <home>/.treehouse, <home>/treehouse,
#                   <home>/workspace, where <home> is PRIMARY_USER's home)
#
# WHAT EACH STEP DOES
#   0. Creates POOL_CONF with placeholder users if missing; reads the active
#      usernames; installs the "acl" package if setfacl is absent; copies
#      SOURCE_AGY_BIN to AGY_BIN (mode 0755, root-owned) when absent or changed.
#   1. Ensures SHARED_GROUP exists, adds PRIMARY_USER to it, and grants the group
#      traverse (x) on PRIMARY_USER's home directory.
#   2. For each pool user: creates it (home, bash shell, SHARED_GROUP member) or
#      verifies it; appends to its ~/.bashrc an "unset" of API-key and proxy
#      variables (so agy uses the subscription login) and "umask 0002"; sets git
#      safe.directory '*' and a worker git identity; reports whether its OAuth
#      token exists. Also sets safe.directory '*' for PRIMARY_USER.
#   3. For each existing REPO_PATHS directory: sets group SHARED_GROUP, group rwX
#      with setgid on directories, access and default ACLs for the group, and
#      core.sharedRepository=group on repositories found within three levels.
#   4. Writes /etc/sudoers.d/firstmate-gpro letting PRIMARY_USER run only
#      /usr/bin/env, AGY_BIN, and the absolute paths of test, find and git
#      (resolved with type -P; the pool launcher runs these via sudo -n) as the
#      listed pool users without a password. The rule is built in a temp file,
#      validated with visudo, then moved into place; an invalid rule never
#      replaces the current one. AGY_BIN must be an absolute path with no
#      whitespace and no sudoers separator (comma, colon, equals, quote).
#
# ADD OR REMOVE AN ACCOUNT
#   Add: append the username to POOL_CONF, re-run this script, then
#   bin/fm-agy-pool-setup.sh apply, then sign in as the new user (setup order 4),
#   then add it to the models allowlist.
#   Remove from rotation: delete the username from POOL_CONF, re-run this script
#   (the sudoers rule shrinks to the remaining users), and remove it from the
#   models allowlist. The Linux user and its home are left in place.
#
# HOW TO UNDO (manual; this script never deletes anything)
#   sudo rm /etc/sudoers.d/firstmate-gpro
#   sudo userdel -r <poolUser>          (each pool user; deletes its home and login)
#   sudo gpasswd -d <PRIMARY_USER> <SHARED_GROUP>; sudo groupdel <SHARED_GROUP>
#   sudo rm <AGY_BIN>                   (only if nothing else uses it)
#   sudo setfacl -R -b <repo path>      (each REPO_PATHS entry, to drop the ACLs)
#   sudo rm /etc/firstmate/gpro-pool.conf

set -euo pipefail

# Prints the active usernames (first field of each non-comment, non-blank line)
# of the pool config $1, one per line. Sourceable so tests can call it directly.
fm_agy_pool_parse_conf() {
  grep -Ev '^[[:space:]]*(#|$)' "$1" | awk '{print $1}' || true
}

# Succeeds when $1 is an absolute path with no whitespace or sudoers separators.
fm_agy_pool_valid_agy_bin() {
  [[ "$1" == /* && "$1" != *[[:space:]]* && "$1" != *[,:=\\\"]* ]]
}

# Prints the sudoers rule text: pool config $1, operator $2, comma-separated pool
# users $3, then the absolute command paths $4... the operator may run as them.
fm_agy_pool_sudoers_rule() {
  local conf="$1" primary="$2" users="$3" cmds
  shift 3
  cmds=$(IFS=,; echo "$*")
  cmds=${cmds//,/, }
  cat <<EOF
# Auto-generated by bin/fm-agy-pool-provision.sh from $conf
Defaults:${primary} env_keep += "TERM COLORTERM LANG LC_ALL"
${primary} ALL=(${users}) NOPASSWD: ${cmds}
EOF
}

# Prints the absolute PATH location of each command named in $@, one per line;
# fails if any is missing (type -P, since command -v returns builtin names).
fm_agy_pool_resolve_helpers() {
  local c p
  for c in "$@"; do
    p=$(type -P "$c") && [[ "$p" == /* ]] || return 1
    echo "$p"
  done
}

fm_agy_pool_provision_usage() {
  sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

fm_agy_pool_provision_main() {
  case "${1:-}" in
    -h|--help) fm_agy_pool_provision_usage; return 0 ;;
    '') ;;
    *) echo "ERROR: unknown argument: $1 (see --help)" >&2; return 2 ;;
  esac

  if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must run as root: sudo $0" >&2
    return 1
  fi

  POOL_CONF="${POOL_CONF:-/etc/firstmate/gpro-pool.conf}"
  PRIMARY_USER="${PRIMARY_USER:-${SUDO_USER:-}}"
  if [[ -z "$PRIMARY_USER" || "$PRIMARY_USER" == root ]]; then
    echo "ERROR: set PRIMARY_USER to the operator account (run via sudo from that account)" >&2
    return 1
  fi
  local primary_home
  primary_home=$(getent passwd "$PRIMARY_USER" | cut -d: -f6)
  if [[ -z "$primary_home" ]]; then
    echo "ERROR: PRIMARY_USER '$PRIMARY_USER' does not exist" >&2
    return 1
  fi
  SHARED_GROUP="${SHARED_GROUP:-agents}"
  SOURCE_AGY_BIN="${SOURCE_AGY_BIN:-$primary_home/.local/bin/agy}"
  AGY_BIN="${AGY_BIN:-/usr/local/bin/agy}"
  if ! fm_agy_pool_valid_agy_bin "$AGY_BIN"; then
    echo "ERROR: AGY_BIN must be an absolute path without whitespace: $AGY_BIN" >&2
    return 1
  fi
  REPO_PATHS="${REPO_PATHS:-$primary_home/firstmate $primary_home/.treehouse $primary_home/treehouse $primary_home/workspace}"

  # 0. Initialize POOL_CONF if missing
  mkdir -p "$(dirname "$POOL_CONF")"
  if [[ ! -f "$POOL_CONF" ]]; then
    cat > "$POOL_CONF" <<'EOF'
# /etc/firstmate/gpro-pool.conf
# Add one isolated Linux username per line for each Google AI Pro subscription.
# Re-run `sudo bin/fm-agy-pool-provision.sh` after adding new accounts.
gpro1
gpro2
EOF
    chmod 0644 "$POOL_CONF"
    echo "[+] Initialized default pool config at $POOL_CONF"
  fi

  local GPRO_USERS
  mapfile -t GPRO_USERS < <(fm_agy_pool_parse_conf "$POOL_CONF")
  if [[ ${#GPRO_USERS[@]} -eq 0 ]]; then
    echo "ERROR: No active users found in $POOL_CONF" >&2
    return 1
  fi

  # Ensure acl package is installed
  if ! command -v setfacl >/dev/null 2>&1; then
    echo "[+] Installing 'acl' package..."
    apt-get update -qq && apt-get install -y -qq acl
  fi

  # Ensure system-wide executable copy of agy exists (update if source is newer)
  if [[ -x "$SOURCE_AGY_BIN" ]]; then
    if [[ ! -x "$AGY_BIN" ]] || ! cmp -s "$SOURCE_AGY_BIN" "$AGY_BIN"; then
      echo "[+] Installing/updating $SOURCE_AGY_BIN -> $AGY_BIN (0755)..."
      install -m 0755 -o root -g root "$SOURCE_AGY_BIN" "$AGY_BIN"
    fi
  elif [[ ! -x "$AGY_BIN" ]]; then
    echo "ERROR: Neither $AGY_BIN nor $SOURCE_AGY_BIN exists." >&2
    return 1
  fi

  echo "=== Dynamic Pool Sync Summary ==="
  echo "POOL_CONF    : $POOL_CONF"
  echo "PRIMARY_USER : $PRIMARY_USER"
  echo "ACTIVE_USERS : ${GPRO_USERS[*]}"
  echo "AGY_BIN      : $AGY_BIN"
  echo "================================="

  # 1. Ensure shared group and home traverse ACL exist
  getent group "$SHARED_GROUP" >/dev/null || groupadd "$SHARED_GROUP"
  usermod -aG "$SHARED_GROUP" "$PRIMARY_USER"
  setfacl -m "g:${SHARED_GROUP}:x" "$primary_home"

  # 2. Idempotently provision every user listed in POOL_CONF
  local u PROFILE_FILE TOKEN_FILE
  for u in "${GPRO_USERS[@]}"; do
    if ! id "$u" >/dev/null 2>&1; then
      useradd -m -s /bin/bash -G "$SHARED_GROUP" "$u"
      echo "[+] Created new isolated user: $u"
    else
      usermod -aG "$SHARED_GROUP" "$u"
      echo "[=] Verified existing user: $u"
    fi

    PROFILE_FILE="/home/$u/.bashrc"
    if ! grep -q "unset GEMINI_API_KEY GOOGLE_API_KEY" "$PROFILE_FILE" 2>/dev/null; then
      {
        echo ""
        echo "# Enforce Google AI Pro subscription OAuth (strip proxy & API key overrides)"
        echo "unset GEMINI_API_KEY GOOGLE_API_KEY ANTHROPIC_BASE_URL OPENAI_BASE_URL LITELLM_BASE_URL"
        echo "umask 0002"
      } >> "$PROFILE_FILE"
      chown "$u:$u" "$PROFILE_FILE"
    fi

    # Idempotent git safe.directory check
    if ! sudo -H -u "$u" git config --global --get-all safe.directory 2>/dev/null | grep -Fxq '*'; then
      sudo -H -u "$u" git config --global --add safe.directory '*'
    fi
    sudo -H -u "$u" git config --global user.name "Firstmate Worker ($u)"
    sudo -H -u "$u" git config --global user.email "${u}@localhost"

    # Check if OAuth token already exists so operator knows who still needs login
    TOKEN_FILE="/home/${u}/.gemini/antigravity-cli/antigravity-oauth-token"
    if [[ -f "$TOKEN_FILE" ]]; then
      echo "    -> OAuth status: AUTHENTICATED ($TOKEN_FILE)"
    else
      echo "    -> OAuth status: PENDING LOGIN (run interactive 'agy' as $u once)"
    fi
  done

  if ! sudo -H -u "$PRIMARY_USER" git config --global --get-all safe.directory 2>/dev/null | grep -Fxq '*'; then
    sudo -H -u "$PRIMARY_USER" git config --global --add safe.directory '*'
  fi

  # 3. Apply setgid + default ACLs across shared repos & Treehouse worktrees
  local repo gitdir
  for repo in $REPO_PATHS; do
    if [[ -d "$repo" ]]; then
      chgrp -R "$SHARED_GROUP" "$repo"
      chmod -R g+rwX "$repo"
      find "$repo" -type d -exec chmod g+s {} +
      setfacl -R -m "g:${SHARED_GROUP}:rwx" "$repo"
      setfacl -R -d -m "g:${SHARED_GROUP}:rwx" "$repo"

      find "$repo" -maxdepth 3 -name ".git" | while read -r gitdir; do
        git -C "$(dirname "$gitdir")" config core.sharedRepository group || true
      done
    fi
  done

  # 4. Regenerate passwordless sudoers rule dynamically for all active POOL_CONF users
  local SUDOERS_FILE="/etc/sudoers.d/firstmate-gpro" USER_LIST_CSV
  USER_LIST_CSV=$(IFS=,; echo "${GPRO_USERS[*]}")

  local helper_out helper_paths
  if ! helper_out=$(fm_agy_pool_resolve_helpers test find git); then
    echo "ERROR: cannot resolve test, find and git to absolute paths" >&2
    exit 1
  fi
  mapfile -t helper_paths <<<"$helper_out"

  # sudo ignores names containing '.', so the temp file is never read while unvalidated.
  local sudoers_tmp
  sudoers_tmp=$(mktemp /etc/sudoers.d/.firstmate-gpro.XXXXXX)
  fm_agy_pool_sudoers_rule "$POOL_CONF" "$PRIMARY_USER" "$USER_LIST_CSV" \
    /usr/bin/env "$AGY_BIN" "${helper_paths[@]}" > "$sudoers_tmp"

  chmod 0440 "$sudoers_tmp"
  if ! visudo -cf "$sudoers_tmp"; then
    rm -f "$sudoers_tmp"
    echo "ERROR: generated sudoers rule is invalid; $SUDOERS_FILE left unchanged." >&2
    exit 1
  fi
  mv -f "$sudoers_tmp" "$SUDOERS_FILE"
  echo "[+] Updated sudoers rule for: $USER_LIST_CSV"
  echo "Next: bin/fm-agy-pool-setup.sh apply, then check; sign in as each pending user."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  fm_agy_pool_provision_main "$@"
fi
