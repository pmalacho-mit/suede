#!/usr/bin/env bash
# The rule for reaching a remote: the recorded spelling first, then the other
# one (SSH <-> HTTPS), or only HTTPS under --https.
#
# It lives in four places - the shipped diff, deps.sh and sync, which cannot
# share a file once vendored into a consumer, and the maintainer's lib.sh - so
# this pins its behaviour once and then holds every copy to it.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/../../.." && pwd)"
source "$ROOT_DIR/.tests/harness/runner.sh"; source "$ROOT_DIR/.tests/harness/color-logging.sh"

COPIES=(
  "$ROOT_DIR/dependency/release/core/diff"
  "$ROOT_DIR/dependency/release/core/deps.sh"
  "$ROOT_DIR/dependency/release/core/sync"
  "$ROOT_DIR/dependency/main/core/lib.sh"
)

extract() { sed -n '/^spellings() { # <url>/,/^}/p' "$1"; }

every_copy_is_identical() {
  local reference copy
  reference="$(extract "${COPIES[3]}")"
  [[ -n "$reference" ]] || { log_failure "no spellings() in lib.sh"; return 1; }
  for copy in "${COPIES[@]}"; do
    if [[ "$(extract "$copy")" == "$reference" ]]; then
      log_pass "${copy#"$ROOT_DIR"/} has the same spellings()"
    else
      log_failure "${copy#"$ROOT_DIR"/} has drifted from lib.sh's spellings()"
      diff <(extract "${COPIES[3]}") <(extract "$copy") >&2 || true
      return 1
    fi
  done
}

# <https-only> <url> <expected, one spelling per line joined with |>
check() {
  local actual
  actual="$(HTTPS_ONLY="$1" bash -c "$(extract "${COPIES[3]}"); spellings \"\$1\"" _ "$2" | paste -sd'|' -)"
  if [[ "$actual" == "$3" ]]; then log_pass "HTTPS_ONLY=$1 $2 -> $3"; return 0; fi
  log_failure "HTTPS_ONLY=$1 $2 -> expected $3, got $actual"; return 1
}

the_recorded_spelling_comes_first_then_the_other() {
  check 0 git@github.com:o/r.git          'git@github.com:o/r.git|https://github.com/o/r.git' &&
  check 0 https://github.com/o/r          'https://github.com/o/r|git@github.com:o/r.git' &&
  check 0 https://github.com/o/r.git      'https://github.com/o/r.git|git@github.com:o/r.git' &&
  check 0 ssh://git@github.com/o/r.git    'ssh://git@github.com/o/r.git|https://github.com/o/r.git'
}

https_only_keeps_just_the_https_spelling() {
  check 1 git@github.com:o/r.git          'https://github.com/o/r.git' &&
  check 1 ssh://git@github.com/o/r.git    'https://github.com/o/r.git' &&
  check 1 https://github.com/o/r          'https://github.com/o/r'
}

a_remote_with_one_spelling_is_left_alone() {
  check 0 /srv/git/r.git                  '/srv/git/r.git' &&
  check 1 /srv/git/r.git                  '/srv/git/r.git' &&
  check 0 file:///srv/git/r.git           'file:///srv/git/r.git' &&
  check 1 ssh://git@host:2222/o/r.git     'ssh://git@host:2222/o/r.git'
}

run_test_suite \
  every_copy_is_identical \
  the_recorded_spelling_comes_first_then_the_other \
  https_only_keeps_just_the_https_spelling \
  a_remote_with_one_spelling_is_left_alone
