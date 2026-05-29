#!/usr/bin/env bash
# Test for degit.sh.
#
# Default: fully offline — content from a local git repo, with degit's GitHub
# tarball/commit endpoints mirrored over file:// (GITHUB_API_ORIGIN).
#
# Opt-in LIVE mode: set SUEDE_TEST_LIVE=1 to fetch the real hosted commits from
# github.com/pmalacho-mit/suede instead (validates real HTTP: auth, redirects,
# rate limits). Honors GITHUB_TOKEN/GH_TOKEN if set, to dodge rate limits.
# Do NOT enable this in the hermetic (`--network none`) CI job.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$(cd "$TESTS_DIR/../../../.tests/harness" && pwd)"
readonly EXTERNAL_DEGIT="https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts/utils/degit.sh"
readonly LOCAL_DEGIT="$TESTS_DIR/../degit.sh"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"
source "$HARNESS/mock-curl.sh"; source "$HARNESS/with-local-suede-chain.sh"
source "$HARNESS/with-single-example-txt-file.sh"   # real OWNER/REPO/COMMITS for LIVE mode

readonly LIVE="${SUEDE_TEST_LIVE:-}"
USE_OWNER=""; USE_REPO=""; USE_COMMITS=(); USE_API_ORIGIN=""
TEST_DIR=""

setup() {
  TEST_DIR="$(mktemp -d)"
  if [[ -n "$LIVE" ]]; then
    log_info "LIVE mode: fetching real commits from github.com/${OWNER}/${REPO}"
    USE_OWNER="$OWNER"; USE_REPO="$REPO"; USE_COMMITS=("${COMMITS[@]}"); USE_API_ORIGIN=""
  else
    log_info "offline mode: file:// mirror (set SUEDE_TEST_LIVE=1 for the real repo)"
    chain_make_offline_origin "$TEST_DIR/origin"
    USE_OWNER="$CHAIN_OWNER"; USE_REPO="$CHAIN_REPO"; USE_COMMITS=("${CHAIN_COMMITS[@]}"); USE_API_ORIGIN="$CHAIN_API_ORIGIN"
  fi
  mock_curl_url "$EXTERNAL_DEGIT" "$LOCAL_DEGIT"   # always run the local script under test
  enable_url_mocking
}
cleanup() { [[ -n "${TEST_DIR:-}" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"; disable_url_mocking; }

# Offline: tarball/commit come from the file:// mirror. Live: no override -> real GitHub.
_degit() {
  if [[ -n "$USE_API_ORIGIN" ]]; then
    GITHUB_API_ORIGIN="$USE_API_ORIGIN" bash <(curl -fsSL "$EXTERNAL_DEGIT") "$@"
  else
    bash <(curl -fsSL "$EXTERNAL_DEGIT") "$@"
  fi
}

fetches_first_commit() {
  local d="$TEST_DIR/first"; mkdir -p "$d"
  _degit --repo "$USE_OWNER/$USE_REPO" --commit "${USE_COMMITS[0]}" --destination "$d"
  assert_offline_contents "$d" 0
}
fetches_second_commit() {
  local d="$TEST_DIR/second"; mkdir -p "$d"
  _degit --repo "$USE_OWNER/$USE_REPO" --commit "${USE_COMMITS[1]}" --destination "$d"
  assert_offline_contents "$d" 1
}
refuses_nonempty_then_succeeds() {
  local d="$TEST_DIR/force"; mkdir -p "$d"; touch "$d/extra.txt"
  if _degit --repo "$USE_OWNER/$USE_REPO" --commit "${USE_COMMITS[1]}" --destination "$d" 2>/dev/null; then
    log_failure "degit should refuse a non-empty destination"; return 1
  fi
  log_pass "degit refuses a non-empty destination"
  rm -f "$d/extra.txt"
  _degit --repo "$USE_OWNER/$USE_REPO" --commit "${USE_COMMITS[1]}" --destination "$d"
  assert_offline_contents "$d" 1
}

run_test_suite --setup setup --cleanup cleanup \
  fetches_first_commit fetches_second_commit refuses_nonempty_then_succeeds
