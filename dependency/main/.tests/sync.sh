#!/usr/bin/env bash
# `sync.sh` — updating every piece of suede machinery a dependency vendors.
#
# The interesting part is not the pulling, it is the two `.gitrepo` files whose
# recorded parent is not a commit in this repository's history. Both refuse a
# plain `git subrepo pull`, for different reasons, and both have to be repaired
# without a maintainer reading a git-subrepo diagnostic.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/../../.." && pwd)"
HARNESS="$(cd "$ROOT_DIR/.tests/harness" && pwd)"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"
source "$HARNESS/with-local-suede-chain.sh"

SYNC="$ROOT_DIR/dependency/main/core/sync.sh"
WORK=""; BARE=""; LIB=""; LIBWORK=""

# A dependency in the shape init leaves behind, plus the two workflow subrepos
# a template repository brings with it.
setup() {
  WORK="$(mktemp -d)"
  BARE="$WORK/dep.git"; LIB="$WORK/suede.git"; LIBWORK="$WORK/libwork"
  chain_seed_remote "$BARE" "$WORK/seed"
  chain_seed_library_branches "$LIB" "$LIBWORK"
  git clone --quiet "$BARE" "$WORK/repo"
  cd "$WORK/repo" && git checkout --quiet main
  git subrepo clone --branch=dependency/main/core "$LIB" .suede/core >/dev/null
  git subrepo clone --branch=release "$BARE" release >/dev/null
  git subrepo clone --branch=dependency/release/core "$LIB" release/.suede/core >/dev/null
  vendor_workflows_as_a_template_would
  cp "$SYNC" .suede/core/sync.sh && git add -A && git commit --quiet -m "vendor sync.sh"
}

cleanup() { [[ -n "$WORK" ]] && rm -rf "$WORK"; }

# "Use this template" copies files into a repository with a fresh history, so
# the .gitrepo arrives naming a parent that exists only in the template. Cloning
# in a scratch repo and copying the result is exactly that.
vendor_workflows_as_a_template_would() {
  local template="$WORK/template" path
  git init --quiet "$template"
  ( cd "$template"
    printf '# template\n' > README.md && git add -A && git commit --quiet -m "template"
    git subrepo clone --branch=dependency/main/workflows "$LIB" .github/workflows >/dev/null
    git subrepo clone --branch=dependency/release/workflows "$LIB" release/.github/workflows >/dev/null )
  for path in .github/workflows release/.github/workflows; do
    mkdir -p "$path" && cp -r "$template/$path/." "$path/"
  done
  git add -A && git commit --quiet -m "workflows, as the template shipped them"
}

sync() { SUEDE_LIBRARY_URL="$LIB" bash .suede/core/sync.sh "$@" 2>&1; }

it_finds_every_library_subrepo_and_no_others() {
  local output; output="$(sync)"

  for expected in .suede/core release/.suede/core .github/workflows release/.github/workflows; do
    grep -q "$expected:" <<<"$output" || {
      log_failure "sync did not touch $expected"; printf '%s\n' "$output" | sed 's/^/    /' >&2; return 1
    }
  done
  log_pass "all four suede subrepos were visited"

  # ./release tracks this repository's own release branch. Publishing owns it.
  if grep -qE '^sync: release: ' <<<"$output"; then
    log_failure "sync pulled ./release, which push-release.sh owns"; return 1
  fi
  log_pass "and ./release itself was left alone"
}

it_repairs_a_parent_that_exists_nowhere_in_this_history() {
  local absent; absent="$(git config -f .github/workflows/.gitrepo --get subrepo.parent)"
  git cat-file -e "$absent" 2>/dev/null && { log_failure "fixture is wrong: parent exists here"; return 1; }
  log_pass "the template left a parent this repository has never seen ($(printf %.7s "$absent"))"

  chain_advance_library_branch "$LIB" "$LIBWORK" dependency/main/workflows "name: workflows v2"
  local output; output="$(sync)"

  grep -q 'repointing at' <<<"$output" || {
    log_failure "sync did not repair the parent"; printf '%s\n' "$output" | sed 's/^/    /' >&2; return 1
  }
  assert_file_matches .github/workflows/subrepo-push-release.yml 'v2' "and the update landed"
}

it_repairs_a_parent_that_belongs_to_another_branch() {
  # What a core vendored onto the release branch before the layout changed looks
  # like: a real commit, but one that is not an ancestor of main.
  local foreign; foreign="$(git rev-parse origin/release)"
  git config -f release/.suede/core/.gitrepo subrepo.parent "$foreign"
  git commit --quiet -am "simulate a core vendored on the release branch"
  git merge-base --is-ancestor "$foreign" HEAD && { log_failure "fixture is wrong: it is an ancestor"; return 1; }

  chain_advance_library_branch "$LIB" "$LIBWORK" dependency/release/core "consumer tools v2"
  sync >/dev/null

  assert_file_matches release/.suede/core/sync 'v2' "the release core updated despite the foreign parent"
}

it_leaves_the_publish_path_usable() {
  # Everything above pulled subrepos nested inside release/. Publishing is the
  # very next thing a maintainer does, and it is what those leave broken.
  if git subrepo push release >/dev/null 2>&1; then
    log_pass "git subrepo push release still works after a sync"
  else
    log_failure "sync left the publish path blocked"
    git subrepo push release 2>&1 | sed 's/^/    /' >&2
    return 1
  fi
}

a_second_run_reports_no_movement() {
  local output; output="$(sync)"

  if grep -q 'already up to date' <<<"$output"; then
    log_pass "a second run says so rather than inventing commits"
  else
    log_failure "expected 'already up to date'"; printf '%s\n' "$output" | sed 's/^/    /' >&2; return 1
  fi
}

run_test_suite --setup setup --cleanup cleanup \
  it_finds_every_library_subrepo_and_no_others \
  it_repairs_a_parent_that_exists_nowhere_in_this_history \
  it_repairs_a_parent_that_belongs_to_another_branch \
  it_leaves_the_publish_path_usable \
  a_second_run_reports_no_movement
