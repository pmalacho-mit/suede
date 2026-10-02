#!/usr/bin/env bash
# The consumer-side `upstream`, against real local repositories.
#
# What has to come out right is which folder gets proposed. A dependency is
# usually reached through a symlink - its declaration (suede.nests.sweater-vest
# -> suede.nests) or an edge - and `git subrepo push` on a symlink path fails,
# so both the shipped stub and the hosted script must resolve to the real
# folder before anything is pushed.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/../../.." && pwd)"
HARNESS="$ROOT_DIR/.tests/harness"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"
source "$HARNESS/with-local-suede-chain.sh"

# Overridable so the test can be pointed at an older copy to prove it bites.
STUB="${SUEDE_TEST_UPSTREAM_STUB:-$ROOT_DIR/dependency/release/core/upstream}"
HOSTED="${SUEDE_TEST_UPSTREAM_HOSTED:-$ROOT_DIR/scripts/upstream.sh}"
export SUEDE_UPSTREAM_URL="file://$HOSTED"
WORK=""

# deps/foo is the real subrepo; suede.foo.app is the declaration pointing at it.
setup() {
  WORK="$(mktemp -d)"
  chain_seed_remote "$WORK/bare" "$WORK/seed"
  chain_make_consumer "$WORK/bare" "$WORK/consumer"
  ( cd "$WORK/consumer"
    mkdir -p deps/foo/.suede/core && cp "$STUB" deps/foo/.suede/core/upstream
    ln -s deps/foo suede.foo.app
    git add -A && git commit --quiet -m "vendor the core, declare foo" )
}
cleanup() { [[ -n "$WORK" ]] && rm -rf "$WORK"; }

# A local change to foo, committed, made through the symlink like any edit.
change() { # <text>
  ( cd "$WORK/consumer"
    printf '%s\n' "$1" >> suede.foo.app/lib/index.js
    git commit --quiet -am "consumer: $1" )
}

proposed_branches() { git ls-remote --heads "$WORK/bare" 'downstream/*' | wc -l | tr -d ' '; }

assert_proposed() { # <count> <text> <label>
  local branch
  if [[ "$(proposed_branches)" != "$1" ]]; then
    log_failure "$3 (expected $1 downstream branch(es), found $(proposed_branches))"; return 1
  fi
  # Branch names end in a commit hash, so their order says nothing: look for
  # the change on any of them.
  for branch in $(git ls-remote --heads "$WORK/bare" 'downstream/*' | awk '{print $2}'); do
    git --git-dir="$WORK/bare" show "$branch:lib/index.js" 2>/dev/null | grep -q "$2" \
      && { log_pass "$3"; return 0; }
  done
  log_failure "$3 (no downstream branch carries the change)"; return 1
}

the_stub_proposes_through_the_declaring_symlink() {
  change "patch one"
  local output status=0
  output="$( cd "$WORK/consumer" && bash suede.foo.app/.suede/core/upstream 2>&1 )" || status=$?
  [[ "$status" == 0 ]] || { log_failure "upstream failed: $output"; return 1; }
  grep -q "Proposing 'deps/foo'" <<<"$output" \
    && log_pass "the real folder, deps/foo, is what gets proposed" \
    || { log_failure "proposed the wrong path: $output"; return 1; }
  assert_proposed 1 "patch one" "a downstream branch carrying the change was pushed"
}

the_hosted_script_resolves_a_symlink_argument_itself() {
  # Older stubs pass the symlink path on; the hosted half must cope alone.
  change "patch two"
  local output status=0
  output="$( cd "$WORK/consumer" && bash "$HOSTED" suede.foo.app 2>&1 )" || status=$?
  [[ "$status" == 0 ]] || { log_failure "hosted upstream failed: $output"; return 1; }
  assert_proposed 2 "patch two" "called with the symlink path, it still proposes deps/foo"
}

run_test_suite --setup setup --cleanup cleanup \
  the_stub_proposes_through_the_declaring_symlink \
  the_hosted_script_resolves_a_symlink_argument_itself
