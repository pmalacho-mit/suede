#!/usr/bin/env bash
# The consumer-side `sync` script, against real local repositories.
#
# It ships inside a dependency and takes no target, so everything worth
# asserting is about what it works out for itself: which folder it is in, where
# the repository root is, and what it hands to `git subrepo pull`.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/../../.." && pwd)"
HARNESS="$(cd "$ROOT_DIR/.tests/harness" && pwd)"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"
source "$HARNESS/with-local-suede-chain.sh"

SYNC="$ROOT_DIR/dependency/release/core/sync"
WORK=""

setup() {
  WORK="$(mktemp -d)"
  chain_seed_remote "$WORK/bare" "$WORK/seed"
  chain_make_consumer "$WORK/bare" "$WORK/consumer"
  # What shipping puts there: the dependency carries its own copy of the script.
  mkdir -p "$WORK/consumer/deps/foo/.suede/core"
  cp "$SYNC" "$WORK/consumer/deps/foo/.suede/core/sync"
  ( cd "$WORK/consumer" && git add -A && git commit --quiet -m "vendor the release core" )
}

cleanup() { [[ -n "$WORK" ]] && rm -rf "$WORK"; }

# A new release commit, carrying <text> as the whole of lib/added.js — so what
# a pull landed can be told apart from what an earlier one did.
publish() { # <text>
  ( cd "$WORK/seed"
    git checkout --quiet release
    printf '%s\n' "$1" > lib/added.js
    git add lib/added.js && git commit --quiet -m "release: $1"
    git push --quiet origin release
    git checkout --quiet main )
}

assert_pulled() { # <text> <label>
  local actual=""
  [[ -f "$WORK/consumer/deps/foo/lib/added.js" ]] \
    && actual="$(cat "$WORK/consumer/deps/foo/lib/added.js")"
  if [[ "$actual" == "$1" ]]; then log_pass "$2"; return 0; fi
  log_failure "$2 (expected '$1', found '${actual:-nothing}')"
  return 1
}

pulls_the_dependency_it_lives_in_from_any_directory() {
  publish "one"

  # Deliberately run from somewhere else entirely: the script is told nothing.
  ( cd "$WORK" && bash "$WORK/consumer/deps/foo/.suede/core/sync" >/dev/null )

  assert_pulled "one" "sync pulled deps/foo without being told where it is"
}

works_through_a_symlink_to_the_dependency() {
  ( cd "$WORK/consumer" && ln -s deps/foo edge.foo \
      && git add edge.foo && git commit --quiet -m "edge entry" )
  publish "two"

  ( cd "$WORK/consumer" && bash edge.foo/.suede/core/sync >/dev/null )

  assert_pulled "two" "reached through a symlink, sync pulled the real folder"
}

passes_its_arguments_on_to_git_subrepo() {
  publish "three"

  # `sync` knows nothing about --message; reaching the commit it writes is
  # what makes --force, --branch and the rest of git-subrepo's options work.
  ( cd "$WORK/consumer" \
      && bash deps/foo/.suede/core/sync --message "PULLED BY SYNC" >/dev/null )

  if git -C "$WORK/consumer" log -1 --format=%B | grep -q "PULLED BY SYNC"; then
    log_pass "options are forwarded to git subrepo pull"
  else
    log_failure "the option did not reach git subrepo pull"
    git -C "$WORK/consumer" log -1 --format=%B | sed 's/^/    /' >&2
    return 1
  fi
}

refuses_where_there_is_no_dependency() {
  local elsewhere="$WORK/consumer/not-a-dependency/.suede/core" output=""
  mkdir -p "$elsewhere"
  cp "$SYNC" "$elsewhere/sync"

  output="$( ( cd "$WORK/consumer" && bash not-a-dependency/.suede/core/sync ) 2>&1 )" \
    && { log_failure "sync ran outside a dependency instead of refusing"; return 1; }

  if grep -q "no .gitrepo" <<<"$output"; then
    log_pass "outside a dependency, sync says why it cannot run"
  else
    log_failure "sync failed for the wrong reason: $output"
    return 1
  fi
}

# Every directory that offers the command, not just the first one `command -v`
# names: an install can be reachable more than one way (a devcontainer feature
# ships both a lib/ on PATH and a /usr/local/bin wrapper), and a test that
# leaves one of them standing proves nothing.
path_without_git_subrepo() {
  local dir keep=()
  while IFS= read -r dir; do
    [[ -n "$dir" && -x "$dir/git-subrepo" ]] && continue
    keep+=("$dir")
  done < <(printf '%s' "$PATH" | tr ':' '\n')
  ( IFS=:; printf '%s' "${keep[*]}" )
}

finds_git_subrepo_through_GIT_SUBREPO_ROOT() {
  local root stripped
  root="$(cd "$(dirname "$(command -v git-subrepo)")/.." && pwd)"
  [[ -f "$root/.rc" ]] || { log_info "no .rc beside git-subrepo; skipping"; return 0; }
  stripped="$(path_without_git_subrepo)"
  if PATH="$stripped" git subrepo --version >/dev/null 2>&1; then
    log_failure "git-subrepo is still reachable; this test would prove nothing"
    return 1
  fi
  publish "four"

  # The install is present but unreachable: exactly the shape left behind for a
  # script that never ran through the shell profile enabling it.
  ( cd "$WORK/consumer"
    PATH="$stripped" GIT_SUBREPO_ROOT="$root" \
    bash deps/foo/.suede/core/sync >/dev/null )

  assert_pulled "four" "with git-subrepo off PATH, GIT_SUBREPO_ROOT/.rc brought it back"
}

run_test_suite --setup setup --cleanup cleanup \
  pulls_the_dependency_it_lives_in_from_any_directory \
  works_through_a_symlink_to_the_dependency \
  passes_its_arguments_on_to_git_subrepo \
  refuses_where_there_is_no_dependency \
  finds_git_subrepo_through_GIT_SUBREPO_ROOT
