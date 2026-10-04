#!/usr/bin/env bash
# The consumer-side `clean` script, against real local repositories.
#
# It resolves which subrepo it is in (through a symlink, too) and removes
# git-subrepo's bookkeeping for it: the subrepo/<path> branch and the scratch
# worktree. Never files, never commits.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/../../.." && pwd)"
HARNESS="$ROOT_DIR/.tests/harness"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"
source "$HARNESS/with-local-suede-chain.sh"

CLEAN="$ROOT_DIR/dependency/release/core/clean"
WORK=""

setup() {
  WORK="$(mktemp -d)"
  chain_seed_remote "$WORK/bare" "$WORK/seed"
  chain_make_consumer "$WORK/bare" "$WORK/consumer"
  ( cd "$WORK/consumer"
    mkdir -p deps/foo/.suede/core && cp "$CLEAN" deps/foo/.suede/core/clean
    ln -s deps/foo foo.app
    git add -A && git commit --quiet -m "vendor clean, declare foo" )
}
cleanup() { [[ -n "$WORK" ]] && rm -rf "$WORK"; }

has_branch() { git -C "$WORK/consumer" show-ref --verify --quiet "refs/heads/subrepo/deps/foo"; }

removes_what_a_stopped_subrepo_command_leaves_behind() {
  ( cd "$WORK/consumer"
    git subrepo branch deps/foo >/dev/null 2>&1
    mkdir -p .git/tmp/subrepo/deps/foo && : > .git/tmp/subrepo/deps/foo/stale )
  has_branch && log_pass "precondition: a subrepo/deps/foo branch exists" || { log_failure "git subrepo branch made none"; return 1; }

  local output status=0
  output="$( cd "$WORK" && bash consumer/foo.app/.suede/core/clean 2>&1 )" || status=$?
  [[ "$status" == 0 ]] || { log_failure "clean failed: $output"; return 1; }

  ! has_branch && log_pass "run through the symlink from elsewhere, it removed the branch" || { log_failure "branch survived"; return 1; }
  [[ ! -e "$WORK/consumer/.git/tmp/subrepo/deps/foo" ]] && log_pass "and the scratch directory" || { log_failure "scratch survived"; return 1; }
  [[ -f "$WORK/consumer/deps/foo/lib/index.js" && -z "$(git -C "$WORK/consumer" status --porcelain)" ]] \
    && log_pass "and touched no files" || { log_failure "the working tree changed"; return 1; }
}

passes_its_arguments_on_to_git_subrepo_clean() {
  ( cd "$WORK/consumer" && git update-ref refs/subrepo/deps/foo/fetch HEAD )
  ( cd "$WORK/consumer" && bash deps/foo/.suede/core/clean --force >/dev/null 2>&1 )
  git -C "$WORK/consumer" show-ref --quiet refs/subrepo/deps/foo/fetch \
    && { log_failure "--force did not reach git subrepo clean"; return 1; } \
    || log_pass "--force reached git subrepo clean and removed the fetched refs"
}

run_test_suite --setup setup --cleanup cleanup \
  removes_what_a_stopped_subrepo_command_leaves_behind \
  passes_its_arguments_on_to_git_subrepo_clean
