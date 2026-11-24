#!/usr/bin/env bash
# bin/fm-agy-pool-provision.sh: the parts that need no root - usage, the
# non-root refusal, and pool config parsing. Never runs the provisioner as root.
set -u

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROVISION="$ROOT/bin/fm-agy-pool-provision.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-pool-provision)

test_help_prints_usage_and_exits_zero() {
  local out rc
  out=$(bash "$PROVISION" --help 2>&1); rc=$?
  [[ $rc -eq 0 ]] || { fail "--help rc=$rc: $out"; return; }
  grep -q 'Usage: sudo bin/fm-agy-pool-provision.sh' <<<"$out" || { fail "usage line missing: $out"; return; }
  grep -q 'POOL_CONF' <<<"$out" || { fail "env vars missing from help: $out"; return; }
  pass "--help prints the usage and header documentation"
}

test_unknown_argument_is_rejected() {
  local out rc
  out=$(bash "$PROVISION" --bogus 2>&1); rc=$?
  [[ $rc -eq 2 ]] || { fail "unknown argument rc=$rc: $out"; return; }
  pass "an unknown argument is rejected with exit 2"
}

test_refuses_when_not_root() {
  if [[ $(id -u) -eq 0 ]]; then
    pass "skipped: running as root"
    return
  fi
  local out rc
  out=$(POOL_CONF="$TMP_ROOT/never-created.conf" bash "$PROVISION" 2>&1); rc=$?
  [[ $rc -eq 1 ]] || { fail "non-root rc=$rc: $out"; return; }
  grep -q 'must run as root' <<<"$out" || { fail "refusal message missing: $out"; return; }
  [[ ! -e "$TMP_ROOT/never-created.conf" ]] || { fail "non-root run created the pool config"; return; }
  pass "a non-root run refuses before touching anything"
}

test_conf_parsing_skips_comments_and_blank_lines() {
  local conf="$TMP_ROOT/pool.conf" out
  printf '# header\n\ngpro1\n   # indented comment\n  gpro2 trailing words\n\t\ngpro3\n' > "$conf"
  # shellcheck disable=SC1090
  out=$(bash -c '. "$1"; fm_agy_pool_parse_conf "$2"' _ "$PROVISION" "$conf")
  [[ "$out" == $'gpro1\ngpro2\ngpro3' ]] || { fail "unexpected parse result: $out"; return; }
  printf '# only comments\n\n' > "$conf"
  out=$(bash -c '. "$1"; fm_agy_pool_parse_conf "$2"' _ "$PROVISION" "$conf")
  [[ -z "$out" ]] || { fail "comment-only conf should parse to nothing: $out"; return; }
  pass "config parsing ignores comments and blank lines and keeps the first word"
}

test_example_conf_parses_to_placeholders() {
  local out
  out=$(bash -c '. "$1"; fm_agy_pool_parse_conf "$2"' _ "$PROVISION" "$ROOT/docs/examples/gpro-pool.conf.example")
  [[ "$out" == $'gpro1\ngpro2' ]] || { fail "example conf parsed to: $out"; return; }
  pass "the example config lists only the placeholder accounts"
}

fm_test_run test_help_prints_usage_and_exits_zero test_unknown_argument_is_rejected test_refuses_when_not_root test_conf_parsing_skips_comments_and_blank_lines test_example_conf_parses_to_placeholders
