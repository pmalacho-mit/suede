#!/usr/bin/env bash
# What `initialize.yml` leaves behind, against real local repositories.
#
# The property under test is not "the files are there" but *which branch put
# them there*: the consumer-facing core has to arrive on `release` by way of
# `main`, so that updating it later never requires checking `release` out.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$(cd "$TESTS_DIR/../../../.tests/harness" && pwd)"
readonly EXTERNAL_INIT="https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts/actions/init.sh"
readonly LOCAL_INIT="$TESTS_DIR/../init.sh"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"
source "$HARNESS/mock-curl.sh"; source "$HARNESS/with-local-suede-chain.sh"

TEST_DIR=""
BARE=""
CORE=""

setup() {
  TEST_DIR="$(mktemp -d)"
  mock_curl_url "$EXTERNAL_INIT" "$LOCAL_INIT"; enable_url_mocking
  BARE="$TEST_DIR/dep.git"
  CORE="$TEST_DIR/suede.git"
  chain_seed_remote "$BARE" "$TEST_DIR/seed"
  chain_seed_library_branches "$CORE" "$TEST_DIR/corework"
  git clone --quiet "$BARE" "$TEST_DIR/main"
  cd "$TEST_DIR/main" && git checkout --quiet main
  ORIGIN_URL="$BARE" CORE_URL="$CORE" bash <(curl -fsSL "$EXTERNAL_INIT") >/dev/null
}

cleanup() { [[ -n "${TEST_DIR:-}" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"; disable_url_mocking; }

# What the `release` BRANCH holds - not the working tree, which is the whole
# question here.
released() { # <path>
  git --git-dir="$BARE" cat-file -p "release:$1" 2>/dev/null
}

both_cores_are_vendored_from_main() {
  assert_file_matches .suede/core/push-release.sh 'maintainer tools' "the maintainer's core is on main"
  assert_file_matches release/.suede/core/sync 'consumer tools' "the consumer's core is inside ./release"
  assert_file_matches release/.suede/core/.gitrepo 'branch = dependency/release/core' \
    "and it is a subrepo, not a copy"
}

the_release_folder_tracks_the_release_branch() {
  local tip; tip="$(git ls-remote --heads "$BARE" release | awk '{print $1}')"
  assert_file_matches release/.gitrepo 'branch = release' ".gitrepo tracks the release branch"
  assert_file_matches release/lib/index.js 'v = 1'        "library content vendored under release/"
  assert_file_matches README.md '# dependency'           "main's own content preserved"
  if [[ "$(git ls-remote --heads "$BARE" release | awk '{print $1}')" == "$tip" ]]; then
    log_pass "the release branch was reached without checking it out"
  fi
}

the_consumer_core_reached_the_release_branch() {
  if [[ -n "$(released .suede/core/sync)" ]]; then
    log_pass "the release branch carries .suede/core, published through main"
  else
    log_failure "the release branch never received .suede/core"
    git --git-dir="$BARE" ls-tree -r --name-only release | sed 's/^/    /' >&2
    return 1
  fi
}

the_core_can_be_updated_without_touching_release() {
  # The library publishes a new consumer core...
  ( cd "$TEST_DIR/corework"
    git checkout --quiet dependency/release/core
    printf 'consumer tools v2\n' > sync
    git commit --quiet -am "release core v2"
    git push --quiet "$CORE" dependency/release/core )

  # ...and the dependency picks it up entirely from main.
  git subrepo pull release/.suede/core --quiet >/dev/null 2>&1 \
    || { log_failure "could not pull the nested core from main"; return 1; }
  assert_file_matches release/.suede/core/sync 'v2' "the update arrived on main" || return 1

  # The publish that follows is where a nested subrepo bites, in the two ways
  # push-release.sh spells out. Do exactly what it does.
  git subrepo clean release/.suede/core >/dev/null 2>&1 || true
  rm -rf .git/tmp/subrepo
  if git subrepo push release >/dev/null 2>&1; then
    log_pass "and republished to the release branch, still never checking it out"
  else
    log_failure "publishing after a nested pull failed"
    return 1
  fi
  [[ "$(released .suede/core/sync)" == *v2* ]] \
    && log_pass "the release branch now carries the updated core" \
    || { log_failure "the release branch did not receive the update"; return 1; }
}

# Guards the reason push-release.sh does the clearing at all: if git-subrepo
# ever stops leaving these behind, this test says so instead of leaving dead
# defensive code in the publish path forever.
a_nested_pull_blocks_the_next_publish_unless_cleaned() {
  ( cd "$TEST_DIR/corework"
    git checkout --quiet dependency/release/core
    printf 'consumer tools v3\n' > sync
    git commit --quiet -am "release core v3"
    git push --quiet "$CORE" dependency/release/core )
  git subrepo pull release/.suede/core --quiet >/dev/null 2>&1

  if git subrepo push release >/dev/null 2>&1; then
    log_failure "expected the leftover ref to block the push; it did not"
    log_info "if git-subrepo fixed this, the clean in push-release.sh can go"
    return 1
  fi
  log_pass "an uncleaned nested pull does block the publish (hence the guard)"

  git subrepo clean release/.suede/core >/dev/null 2>&1
  rm -rf .git/tmp/subrepo
  git subrepo push release >/dev/null 2>&1 \
    && log_pass "and cleaning it unblocks the publish" \
    || { log_failure "cleaning did not unblock the publish"; return 1; }
}

run_test_suite --setup setup --cleanup cleanup \
  both_cores_are_vendored_from_main \
  the_release_folder_tracks_the_release_branch \
  the_consumer_core_reached_the_release_branch \
  the_core_can_be_updated_without_touching_release \
  a_nested_pull_blocks_the_next_publish_unless_cleaned
