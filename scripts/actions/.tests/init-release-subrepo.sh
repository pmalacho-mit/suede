#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$(cd "$TESTS_DIR/../../../.tests/harness" && pwd)"
readonly EXTERNAL_INIT="https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts/actions/init-release-subrepo.sh"
readonly LOCAL_INIT="$TESTS_DIR/../init-release-subrepo.sh"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"
source "$HARNESS/mock-curl.sh"; source "$HARNESS/with-local-suede-chain.sh"

TEST_DIR=""
setup()   { TEST_DIR="$(mktemp -d)"; mock_curl_url "$EXTERNAL_INIT" "$LOCAL_INIT"; enable_url_mocking; }
cleanup() { [[ -n "${TEST_DIR:-}" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"; disable_url_mocking; }

connects_release_folder_to_release_branch() {
  local bare="$TEST_DIR/dep.git"
  chain_seed_remote "$bare" "$TEST_DIR/seed"
  git clone --quiet "$bare" "$TEST_DIR/main"; cd "$TEST_DIR/main"; git checkout --quiet main
  ORIGIN_URL="$bare" bash <(curl -fsSL "$EXTERNAL_INIT")
  local reltip; reltip="$(git ls-remote --heads "$bare" release | awk '{print $1}')"
  assert_file_matches release/.gitrepo 'branch = release'      ".gitrepo tracks the release branch"
  assert_file_matches release/.gitrepo "commit = $reltip"     ".gitrepo points at the release tip"
  assert_file_matches release/lib/index.js 'v = 1'            "library content vendored under release/"
  assert_file_matches README.md '# dependency'               "main's own content preserved"
}

run_test_suite --setup setup --cleanup cleanup connects_release_folder_to_release_branch
