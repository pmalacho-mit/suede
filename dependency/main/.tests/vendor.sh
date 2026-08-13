#!/usr/bin/env bash
# vendor.sh, against a real working tree.
#
# Vendoring is a move plus two pieces of honesty: where the bytes land, and
# what the move leaves broken. The destination is the top of release/ because
# that is the only place every language can import from - a leading dot is
# unrepresentable in a Python import - and what it leaves broken is any sibling
# the dependency's own manifest asks for that did not come with it.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/../../.." && pwd)"
HARNESS="$(cd "$ROOT_DIR/.tests/harness" && pwd)"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"

VENDOR="$ROOT_DIR/dependency/main/core/vendor.sh"
SCRATCH=""
WORK=""
OUTPUT=""
STATUS=0

# Each test runs in its own subshell, so a tree it creates cannot be cleaned up
# by name afterwards. One scratch directory made here, in the parent, is what
# the cleanup below can actually reach.
setup() { SCRATCH="$(mktemp -d)"; }

# A project named `app` with one release dependency, in whichever of the two
# equivalent forms the test asks for.
seed() { # <form: folder|symlink>
  WORK="$(mktemp -d -p "$SCRATCH")"
  cd "$WORK"
  git init --quiet --initial-branch=main .
  git config user.name "suede tests"
  git config user.email "tests@example.test"
  mkdir -p release
  printf 'export * from "../app.dep";\n' > release/index.ts
  if [[ "$1" == "symlink" ]]; then
    mkdir -p deps/dep && dependency_files deps/dep
    ln -s deps/dep app.dep
  else
    mkdir -p app.dep && dependency_files app.dep
  fi
  git add -A && git commit --quiet -m "initial"
}

dependency_files() { # <folder>
  printf '[subrepo]\n\tremote = https://example.test/acme/dep\n\tcommit = %s\n' "$(printf 'a%.0s' {1..40})" > "$1/.gitrepo"
  printf 'export const dep = 1;\n' > "$1/index.ts"
}

declares_a_sibling() { # <folder> <entry name>
  mkdir -p "$1/.suede/.dependencies"
  printf '[subrepo]\n\tremote = https://example.test/acme/other\n\tcommit = %s\n' \
    "$(printf 'b%.0s' {1..40})" > "$1/.suede/.dependencies/$2.gitrepo"
}

# `return 0` deliberately: this runs from an EXIT trap, where a false last
# command becomes the suite's exit status.
cleanup() { [[ -n "$SCRATCH" ]] && rm -rf "$SCRATCH"; return 0; }

run_vendor() { # <args...>
  STATUS=0
  OUTPUT="$( ( cd "$WORK" && bash "$VENDOR" "$@" ) 2>&1 )" || STATUS=$?
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

assert_path() { # <path> <label>
  [[ -e "$WORK/$1" ]] && { log_pass "$2"; return 0; }
  log_failure "$2 (missing $1)"; return 1
}

assert_no_path() { # <path> <label>
  [[ -e "$WORK/$1" || -L "$WORK/$1" ]] && { log_failure "$2 ($1 is still there)"; return 1; }
  log_pass "$2"
}

the_default_destination_is_the_top_of_release() {
  seed folder

  run_vendor app.dep

  assert_path "release/dep/.gitrepo" "the bytes land at release/<name>" || return 1
  assert_path "release/dep/index.ts" "source and all" || return 1
  assert_no_path "app.dep" "and the old location is gone"
}

nothing_is_nested_under_a_dotted_directory() {
  # `release/.suede/vendor/dep` was the old default and cannot be imported by
  # a Python consumer at all.
  seed folder

  run_vendor app.dep

  assert_no_path "release/.suede" "no dotted directory is invented"
}

a_symlinked_entry_moves_its_backing_folder_and_drops_the_link() {
  seed symlink

  run_vendor app.dep

  assert_path "release/dep/.gitrepo" "the backing folder is what moved" || return 1
  assert_no_path "deps/dep" "from wherever the author kept it" || return 1
  assert_no_path "app.dep" "and the root entry that announced it is removed"
}

dest_still_overrides_the_default() {
  seed folder

  run_vendor app.dep --dest release/vendor/dep

  assert_path "release/vendor/dep/.gitrepo" "--dest is honoured verbatim"
}

imports_of_the_old_entry_name_are_reported() {
  seed folder

  run_vendor app.dep

  assert_shows "release/index.ts" "the file importing ../app.dep is named for review"
}

siblings_it_needs_are_named_because_they_have_to_ship_too() {
  seed folder
  declares_a_sibling app.dep dep.other

  run_vendor app.dep

  assert_shows "dep\.other" "the sibling its manifest asks for is named" || return 1
  assert_shows "vendor these too" "and what to do about it is said"
}

a_dependency_that_needs_nothing_says_nothing() {
  seed folder

  run_vendor app.dep

  assert_hides "vendor these too" "no sibling report where there are no siblings"
}

already_inside_release_is_refused() {
  seed folder
  run_vendor app.dep

  run_vendor release/dep

  [[ $STATUS -ne 0 ]] || { log_failure "vendoring twice should fail"; return 1; }
  assert_shows "already vendored" "and says which rule it broke"
}

run_test_suite --setup setup --cleanup cleanup \
  the_default_destination_is_the_top_of_release \
  nothing_is_nested_under_a_dotted_directory \
  a_symlinked_entry_moves_its_backing_folder_and_drops_the_link \
  dest_still_overrides_the_default \
  imports_of_the_old_entry_name_are_reported \
  siblings_it_needs_are_named_because_they_have_to_ship_too \
  a_dependency_that_needs_nothing_says_nothing \
  already_inside_release_is_refused
