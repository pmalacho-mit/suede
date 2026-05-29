#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$(cd "$TESTS_DIR/../../../.tests/harness" && pwd)"
readonly EXTERNAL_INIT="https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts/actions/init-release-subrepo.sh"
readonly LOCAL_INIT="$TESTS_DIR/../init-release-subrepo.sh"
readonly EXTERNAL_SYNC="https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts/actions/push-release.sh"
readonly LOCAL_SYNC="$TESTS_DIR/../push-release.sh"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"
source "$HARNESS/mock-curl.sh"; source "$HARNESS/with-local-suede-chain.sh"

TEST_DIR=""
setup() {
  TEST_DIR="$(mktemp -d)"
  mock_curl_url "$EXTERNAL_INIT" "$LOCAL_INIT"
  mock_curl_url "$EXTERNAL_SYNC" "$LOCAL_SYNC"
  enable_url_mocking
  chain_seed_remote "$TEST_DIR/dep.git" "$TEST_DIR/seed"
  git clone --quiet "$TEST_DIR/dep.git" "$TEST_DIR/main"
  ( cd "$TEST_DIR/main"; git checkout --quiet main; ORIGIN_URL="$TEST_DIR/dep.git" bash <(curl -fsSL "$EXTERNAL_INIT") >/dev/null )
  chain_make_consumer "$TEST_DIR/dep.git" "$TEST_DIR/consumer"   # vendors v1 BEFORE the change
}
cleanup() { [[ -n "${TEST_DIR:-}" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"; disable_url_mocking; }

author_change_syncs_out_to_release() {
  cd "$TEST_DIR/main"
  printf 'export const v = 2;\nexport const feature = "new";\n' > release/lib/index.js
  git commit --quiet -am "feat: library v2"
  bash <(curl -fsSL "$EXTERNAL_SYNC")
  assert_release_matches "$TEST_DIR/dep.git" lib/index.js 'v = 2' "release branch advanced to v2"
}

consumer_pull_receives_the_change() {
  cd "$TEST_DIR/consumer"
  assert_file_matches deps/foo/lib/index.js 'v = 1' "consumer was on v1 before pulling"
  git subrepo pull deps/foo --quiet
  assert_file_matches deps/foo/lib/index.js 'v = 2' "consumer has v2 after pull"
  assert_clean_tree "consumer tree clean after pull (no conflict)"
}

run_test_suite --setup setup --cleanup cleanup   author_change_syncs_out_to_release   consumer_pull_receives_the_change
