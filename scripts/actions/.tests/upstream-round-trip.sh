#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$(cd "$TESTS_DIR/../../../.tests/harness" && pwd)"
readonly EXTERNAL_UPSTREAM="https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts/upstream.sh"
readonly LOCAL_UPSTREAM="$TESTS_DIR/../../upstream.sh"
readonly EXTERNAL_INIT="https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts/actions/init.sh"
readonly LOCAL_INIT="$TESTS_DIR/../init.sh"
readonly EXTERNAL_REBUILD="https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/dependency/main/core/rebuild-pr-branch.sh"
readonly LOCAL_REBUILD="$TESTS_DIR/../../../dependency/main/core/rebuild-pr-branch.sh"
readonly ROOT_DIR="$(cd "$TESTS_DIR/../../.." && pwd)"
readonly PUSH_RELEASE="$ROOT_DIR/dependency/main/core/push-release.sh"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"
source "$HARNESS/mock-curl.sh"; source "$HARNESS/with-local-suede-chain.sh"

TEST_DIR=""; MERGE_METHOD="${MERGE_METHOD:-ff-only}"
setup() {
  TEST_DIR="$(mktemp -d)"
  mock_curl_url "$EXTERNAL_UPSTREAM" "$LOCAL_UPSTREAM"
  mock_curl_url "$EXTERNAL_INIT"     "$LOCAL_INIT"
  mock_curl_url "$EXTERNAL_REBUILD"  "$LOCAL_REBUILD"
  enable_url_mocking
  chain_seed_remote "$TEST_DIR/dep.git" "$TEST_DIR/seed"
  chain_seed_library_branches "$TEST_DIR/suede.git" "$TEST_DIR/corework"
  git clone --quiet "$TEST_DIR/dep.git" "$TEST_DIR/main"
  # Init for real, cores and all: the round trip then runs against a release
  # folder with a subrepo nested inside it, which is what push-release.sh has
  # to cope with on every publish.
  ( cd "$TEST_DIR/main"; git checkout --quiet main
    ORIGIN_URL="$TEST_DIR/dep.git" CORE_URL="$TEST_DIR/suede.git" \
      bash <(curl -fsSL "$EXTERNAL_INIT") >/dev/null )
  chain_make_consumer "$TEST_DIR/dep.git" "$TEST_DIR/consumer"
}
cleanup() { [[ -n "${TEST_DIR:-}" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"; disable_url_mocking; }

full_round_trip_returns_change_cleanly() {
  local bare="$TEST_DIR/dep.git"

  # consumer makes a change and upstreams it (scripts/upstream.sh)
  cd "$TEST_DIR/consumer"
  printf 'export const v = 1;\nexport const patch = true;\n' > deps/foo/lib/index.js
  git commit --quiet -am "consumer: add a useful patch"
  bash <(curl -fsSL "$EXTERNAL_UPSTREAM") deps/foo
  local branch; branch="$(git ls-remote --heads "$bare" 'downstream/*' | awk '{print $2}' | sed 's#refs/heads/##' | head -1)"
  [[ -n "$branch" ]] && log_pass "upstream created $branch" || { log_failure "no downstream branch"; return 1; }

  # downstream-to-main action: rebuild a main-shaped PR head
  git clone --quiet "$bare" "$TEST_DIR/action" >/dev/null 2>&1; cd "$TEST_DIR/action"
  SUBMISSION_REF="$branch" bash <(curl -fsSL "$EXTERNAL_REBUILD") >/dev/null
  assert_file_matches release/lib/index.js 'patch = true' "PR head carries the patch under release/"

  # simulate the PR merge into main, then the main->release sync
  git checkout --quiet main
  case "$MERGE_METHOD" in
    ff-only) git merge --quiet --ff-only pull-request-head ;;
    merge)   git merge --quiet --no-ff -m "merge" pull-request-head ;;
    squash)  git merge --quiet --squash pull-request-head && git commit --quiet -m "squash" ;;
  esac
  git push --quiet origin main
  SUEDE_PY="$ROOT_DIR/scripts/suede.py" bash "$PUSH_RELEASE" >/dev/null
  assert_release_matches "$bare" lib/index.js 'patch = true' "release advanced with the patch"

  # consumer pulls the now-vetted release — no clobber
  cd "$TEST_DIR/consumer"; git subrepo pull deps/foo --quiet
  assert_file_matches deps/foo/lib/index.js 'patch = true' "consumer's patch survived the round trip"
  assert_clean_tree "consumer tree clean (clean merge)"
}

second_consumer_receives_vetted_change() {
  chain_make_consumer "$TEST_DIR/dep.git" "$TEST_DIR/consumer2"
  assert_file_matches "$TEST_DIR/consumer2/deps/foo/lib/index.js" 'patch = true' "fresh consumer receives the vetted patch"
}

run_test_suite --setup setup --cleanup cleanup   full_round_trip_returns_change_cleanly   second_consumer_receives_vetted_change
