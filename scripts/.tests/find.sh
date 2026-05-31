#!/usr/bin/env bash
# Offline unit test for find.sh — no network, no curl. Exercises subrepo
# discovery and the --top-level filter (which drops any .gitrepo nested beneath
# another .gitrepo) against a synthetic git repo with multi-level nesting.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
HARNESS="$(cd "$TESTS_DIR/../../.tests/harness" && pwd)"
readonly LOCAL_FIND="$SCRIPTS_DIR/find.sh"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"

REPO=""

# A git repo whose subrepo layout (dirs holding a .gitrepo) is:
#   a                 top-level
#   a/nested          nested under a
#   a/nested/deeper   3 levels deep (still chained off a)
#   b                 top-level
#   b/c/d             nested under b, with a non-subrepo dir (c) in between
# plus plain/ (no .gitrepo), which must never be reported.
setup() {
  REPO="$(mktemp -d)"
  git -C "$REPO" init --quiet
  local d
  for d in a a/nested a/nested/deeper b b/c/d plain; do mkdir -p "$REPO/$d"; done
  for d in a a/nested a/nested/deeper b b/c/d; do printf '[subrepo]\n' > "$REPO/$d/.gitrepo"; done
  printf 'x\n' > "$REPO/plain/file.txt"
}
cleanup() { [[ -n "${REPO:-}" && -d "$REPO" ]] && rm -rf "$REPO"; }

# Run find.sh from <cwd> (a dir inside REPO) with the remaining args, returning
# its output as repo-relative paths (absolute prefix stripped). find.sh already
# sorts, and stripping a common prefix preserves that order.
find_rel() { # <cwd> [args...]
  local cwd="$1"; shift
  ( cd "$cwd" && bash "$LOCAL_FIND" "$@" ) | sed "s#^$REPO/##"
}

assert_lines_eq() { # <label> <actual> <expected>
  if [[ "$2" == "$3" ]]; then log_pass "$1"; return 0; fi
  log_failure "$1"
  log_info "expected: $(printf '%s' "$3" | tr '\n' '|')"
  log_info "actual:   $(printf '%s' "$2" | tr '\n' '|')"
  return 1
}

# Without --top-level, every .gitrepo dir under the scope is reported.
finds_every_subrepo_without_flag() {
  assert_lines_eq "default scope finds all 5 subrepos" \
    "$(find_rel "$REPO")" \
    "a
a/nested
a/nested/deeper
b
b/c/d"
}

# --top-level keeps only the outermost subrepo on each path (a, b); everything
# nested below the first .gitrepo — including the 3-levels-deep a/nested/deeper
# and b/c/d (whose intermediate dir c is NOT a subrepo) — is dropped.
top_level_keeps_only_outermost() {
  assert_lines_eq "--top-level keeps only a and b" \
    "$(find_rel "$REPO" --top-level)" \
    "a
b"
}

# A non-subrepo directory between two .gitrepos must not "reset" the chain:
# b/c/d is still nested because its ancestor b is a subrepo.
intermediate_plain_dir_does_not_reset_nesting() {
  assert_lines_eq "b/c/d visible without flag" "$(find_rel "$REPO" 'b/**')" "b/c/d"
  assert_lines_eq "b/c/d excluded with --top-level" "$(find_rel "$REPO" --top-level 'b/**')" ""
}

# Even when a glob targets a nested subrepo directly, --top-level still excludes
# it (filtering is per-dir against the full repo set, not the matched subset).
directly_targeted_nested_subrepo_is_excluded() {
  assert_lines_eq "a/* matches a/nested without flag" "$(find_rel "$REPO" 'a/*')" "a/nested"
  assert_lines_eq "a/* yields nothing with --top-level" "$(find_rel "$REPO" --top-level 'a/*')" ""
}

# Scoping into a subrepo yields no top-level results: the scope root (a) is
# itself a subrepo, so everything beneath it is nested.
scoping_into_a_subrepo_yields_nothing_top_level() {
  assert_lines_eq "inside a/, contents visible without flag" \
    "$(find_rel "$REPO/a")" \
    "a/nested
a/nested/deeper"
  assert_lines_eq "inside a/, nothing is top-level" "$(find_rel "$REPO/a" --top-level)" ""
}

unknown_option_is_rejected() {
  local rc=0
  ( cd "$REPO" && bash "$LOCAL_FIND" --bogus ) >/dev/null 2>&1 || rc=$?
  if [[ $rc -ne 0 ]]; then log_pass "unknown option exits non-zero (rc=$rc)"; return 0; fi
  log_failure "unknown option should exit non-zero"; return 1
}

help_prints_usage_and_exits_zero() {
  local out
  out="$( cd "$REPO" && bash "$LOCAL_FIND" --help )"
  if grep -q 'Usage:' <<<"$out" && grep -q -- '--top-level' <<<"$out"; then
    log_pass "--help prints usage including --top-level"; return 0
  fi
  log_failure "--help should print usage mentioning --top-level"; return 1
}

run_test_suite --setup setup --cleanup cleanup \
  finds_every_subrepo_without_flag \
  top_level_keeps_only_outermost \
  intermediate_plain_dir_does_not_reset_nesting \
  directly_targeted_nested_subrepo_is_excluded \
  scoping_into_a_subrepo_yields_nothing_top_level \
  unknown_option_is_rejected \
  help_prints_usage_and_exits_zero
