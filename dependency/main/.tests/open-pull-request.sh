#!/usr/bin/env bash
# The PR description and the backend seam.
#
# "Open a PR" is the one step that differs between forges, so it is behind a
# backend switch; `print` is that seam observed from the outside, and is what
# lets the description be asserted without a forge at all.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$TESTS_DIR/../core" && pwd)"
HARNESS="$(cd "$TESTS_DIR/../../../.tests/harness" && pwd)"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"

readonly OPEN_PR="$CORE_DIR/open-pull-request.sh"

TEST_DIR=""; BASE=""; TIP=""
setup() {
  TEST_DIR="$(mktemp -d)"
  git init --quiet "$TEST_DIR/repo"
  cd "$TEST_DIR/repo"
  git config user.email t@example.test; git config user.name t
  printf 'v0\n' > file.txt; git add .; git commit --quiet -m "base"
  BASE="$(git rev-parse HEAD)"
  printf 'v1\n' > file.txt; git commit --quiet -am "teach the widget to spin"
  TIP="$(git rev-parse HEAD)"
}
cleanup() { [[ -n "${TEST_DIR:-}" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"; }

describe() {
  ( cd "$TEST_DIR/repo" && SUEDE_PR_BACKEND=print SUBMISSION_REF="downstream/app-abc123" \
      BASE_COMMIT="$BASE" SUBMISSION_COMMIT="$TIP" CONFLICTED="${1:-false}" \
      bash "$OPEN_PR" ) > "$TEST_DIR/body.md"
}

assert_body() {
  local needle="$1" description="$2"
  if grep -q -- "$needle" "$TEST_DIR/body.md"; then log_pass "$description"
  else log_failure "$description"; cat "$TEST_DIR/body.md" >&2; return 1; fi
}

refute_body() {
  local needle="$1" description="$2"
  if grep -q -- "$needle" "$TEST_DIR/body.md"; then
    log_failure "$description"; cat "$TEST_DIR/body.md" >&2; return 1
  fi
  log_pass "$description"
}

the_description_names_the_provenance() {
  describe
  assert_body "downstream/app-abc123" "the branch is named"
  assert_body "$BASE" "the consumer's release base is named"
}

the_description_lists_the_submitted_commits() {
  describe
  assert_body "teach the widget to spin" "each submitted commit is listed"
}

a_clean_submission_carries_no_conflict_notice() {
  describe false
  refute_body "Unresolved conflict markers" "no conflict notice when there are none"
}

a_conflicted_submission_says_so_first() {
  describe true
  assert_body "Unresolved conflict markers" "the conflict notice is present"
}

an_unknown_backend_is_a_usage_error() {
  local status=0
  ( cd "$TEST_DIR/repo" && SUEDE_PR_BACKEND=carrier-pigeon SUBMISSION_REF=x BASE_COMMIT="$BASE" \
      SUBMISSION_COMMIT="$TIP" bash "$OPEN_PR" ) >/dev/null 2>&1 || status=$?
  [[ "$status" -eq 2 ]] || { log_failure "an unknown backend exits 2"; return 1; }
  log_pass "an unknown backend exits 2"
}

run_test_suite --setup setup --cleanup cleanup \
  the_description_names_the_provenance \
  the_description_lists_the_submitted_commits \
  a_clean_submission_carries_no_conflict_notice \
  a_conflicted_submission_says_so_first \
  an_unknown_backend_is_a_usage_error
