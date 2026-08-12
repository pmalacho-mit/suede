#!/usr/bin/env bash
# The consumer-side `diff` script, against real local repositories.
#
# Two questions have to come out right: what would I propose (my tree against
# the commit I pinned), and what would I receive (my tree against the tip). The
# rest is about what belongs in that comparison - uncommitted work yes, ignored
# files no, `.gitrepo` never - and about an exit code a caller can act on.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/../../.." && pwd)"
HARNESS="$(cd "$ROOT_DIR/.tests/harness" && pwd)"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"
source "$HARNESS/with-local-suede-chain.sh"

DIFF="$ROOT_DIR/dependency/release/core/diff"
WORK=""
OUTPUT=""
STATUS=0

setup() {
  WORK="$(mktemp -d)"
  chain_seed_remote "$WORK/bare" "$WORK/seed"
  # Publish the script the way a real release does, so both sides of the
  # comparison have it and it is not itself a difference.
  ( cd "$WORK/seed"
    git checkout --quiet release
    mkdir -p .suede/core && cp "$DIFF" .suede/core/diff
    git add -A && git commit --quiet -m "release: vendor the core"
    git push --quiet origin release
    git checkout --quiet main )
  chain_make_consumer "$WORK/bare" "$WORK/consumer"
}

cleanup() { [[ -n "$WORK" ]] && rm -rf "$WORK"; }

# A new release commit, so the consumer's pin falls behind the tip.
publish() { # <text>
  ( cd "$WORK/seed"
    git checkout --quiet release
    printf '%s\n' "$1" > lib/index.js
    git commit --quiet -am "release: $1"
    git push --quiet origin release
    git checkout --quiet main )
}

# Runs the script, keeping stdout+stderr and the exit code for assertions.
run_diff() { # <args...>
  STATUS=0
  OUTPUT="$( ( cd "$WORK/consumer" && bash deps/foo/.suede/core/diff "$@" ) 2>&1 )" || STATUS=$?
}

assert_shows() { # <ere> <label>
  if grep -qE "$1" <<<"$OUTPUT"; then log_pass "$2"; return 0; fi
  log_failure "$2"; printf '%s\n' "$OUTPUT" | sed 's/^/    /' >&2; return 1
}

assert_hides() { # <ere> <label>
  if grep -qE "$1" <<<"$OUTPUT"; then
    log_failure "$2"; printf '%s\n' "$OUTPUT" | sed 's/^/    /' >&2; return 1
  fi
  log_pass "$2"
}

assert_status() { # <expected> <label>
  if [[ "$STATUS" == "$1" ]]; then log_pass "$2"; return 0; fi
  log_failure "$2 (expected exit $1, got $STATUS)"; return 1
}

an_untouched_dependency_differs_in_nothing() {
  run_diff

  assert_status 0 "an untouched dependency exits 0" || return 1
  assert_shows "no differences" "and says there are no differences"
}

local_work_reads_as_what_you_would_propose() {
  ( cd "$WORK/consumer"
    printf 'export const v = 99;\n' > deps/foo/lib/index.js   # an uncommitted edit
    printf 'brand new\n' > deps/foo/lib/added.js )            # never committed at all

  run_diff

  assert_status 1 "a changed dependency exits 1, the way git diff does" || return 1
  assert_shows '^\+export const v = 99;' "the uncommitted edit is a + line" || return 1
  assert_shows 'local/lib/added.js' "a file you only just created is included too"
}

ignored_files_and_gitrepo_stay_out_of_it() {
  ( cd "$WORK/consumer"
    printf 'lib/build.js\n' > deps/foo/.gitignore
    printf 'generated\n' > deps/foo/lib/build.js )

  run_diff

  # The path as a diff header would carry it - the name also appears as the
  # body of the .gitignore that was just added, which is not the same thing.
  assert_hides 'local/lib/build\.js' "an ignored file is not a change you would propose" || return 1
  assert_hides '\.gitrepo' "the .gitrepo is left out of both sides"
}

sync_shows_what_the_tip_would_bring() {
  publish "export const v = 2;"

  run_diff --sync

  assert_shows 'pinned [0-9a-f]{7} -> tip of release [0-9a-f]{7}' "the pin and the tip are named" || return 1
  assert_shows '^\+export const v = 2;' "what the tip has and you do not is a + line" || return 1
  assert_shows 'incoming' "and the output says which half is incoming"
}

sync_says_so_when_the_pin_is_already_the_tip() {
  # Catch up to the tip the way a sync would, without needing git-subrepo.
  ( cd "$WORK/consumer"
    local tip
    tip="$(git ls-remote "$WORK/bare" refs/heads/release | cut -f1)"
    git config -f deps/foo/.gitrepo subrepo.commit "$tip" )

  run_diff --sync

  assert_shows "already pinned at the tip" "being level with the tip is stated, not left to be inferred"
}

arguments_reach_git_diff() {
  run_diff --name-only

  assert_shows '^local/lib/added\.js$' "--name-only reached git diff"
}

outside_a_dependency_it_refuses_distinguishably() {
  local elsewhere="$WORK/consumer/not-a-dependency/.suede/core"
  mkdir -p "$elsewhere" && cp "$DIFF" "$elsewhere/diff"
  STATUS=0
  OUTPUT="$( ( cd "$WORK/consumer" && bash not-a-dependency/.suede/core/diff ) 2>&1 )" || STATUS=$?

  # 2, not 1: a caller has to be able to tell "there is a difference" from
  # "I could not look".
  assert_status 2 "a failure exits 2, not git diff's 1" || return 1
  assert_shows "no .gitrepo" "and says why"
}

run_test_suite --setup setup --cleanup cleanup \
  an_untouched_dependency_differs_in_nothing \
  local_work_reads_as_what_you_would_propose \
  ignored_files_and_gitrepo_stay_out_of_it \
  sync_shows_what_the_tip_would_bring \
  sync_says_so_when_the_pin_is_already_the_tip \
  arguments_reach_git_diff \
  outside_a_dependency_it_refuses_distinguishably
