#!/usr/bin/env bash
# The publish guard, against real local repositories.
#
# What is worth pinning here is the refusal: a release dependency ships as a
# pointer, so a diverged dependency or a declared sibling that is not there
# must stop the publish rather than send a lie out to consumers. Those cases
# stop before the remote is touched, so they need no git-subrepo.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$TESTS_DIR/../core" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/../../.." && pwd)"
HARNESS="$ROOT_DIR/.tests/harness"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"
source "$HARNESS/with-suede-graph.sh"

readonly PUSH_RELEASE="$CORE_DIR/push-release.sh"
INSTALL="$ROOT_DIR/scripts/install/release.sh"
WORK=""; OUT=""

# widget <- gadget, and a library declaring gadget (and so, after the recipe,
# widget) as release dependencies of its own.
setup() {
  WORK="$(mktemp -d)"
  local widget
  widget="$(graph_make_dep "$WORK" widget)"
  graph_make_dep "$WORK" gadget "gadget.widget=$(graph_remote "$WORK" widget)@$widget" >/dev/null
  graph_make_project "$WORK" library --dependency
  ( cd "$WORK/library"
    bash "$INSTALL" --repo "$(graph_remote "$WORK" gadget)" >/dev/null 2>&1
    bash "$INSTALL" --repo "$(graph_remote "$WORK" widget)" >/dev/null 2>&1
    ln -s widget gadget.widget
    git add -A; git commit --quiet -m "install gadget" )
  OUT="$WORK/out.txt"
}
cleanup() { [[ -n "$WORK" ]] && rm -rf "$WORK"; }

# DRY_RUN stops after the guard, which is everything these cases are about.
guard() { ( cd "$WORK/library" && DRY_RUN=1 bash "$PUSH_RELEASE" ) > "$OUT" 2>&1; }

assert_reports() {
  local needle="$1" description="$2"
  if grep -q -- "$needle" "$OUT"; then log_pass "$description"; else log_failure "$description"; cat "$OUT" >&2; return 1; fi
}

an_honest_tree_passes_the_guard() {
  guard || { log_failure "guard failed on a clean tree"; cat "$OUT" >&2; return 1; }
  log_pass "guard passed on a clean tree"
}

the_records_are_refreshed_and_committed() {
  [[ -f "$WORK/library/release/.suede/.dependencies/library.gadget.gitrepo" ]] \
    && log_pass "extract recorded gadget" || { log_failure "no gadget record"; return 1; }
  [[ -f "$WORK/library/release/.suede/.dependencies/library.widget.gitrepo" ]] \
    && log_pass "and widget, which the recipe declared" || return 1
  git -C "$WORK/library" log -1 --format=%s | grep -q 'update dependency records' \
    && log_pass "and committed them" || { log_failure "no commit"; return 1; }
  git -C "$WORK/library" diff --quiet && log_pass "leaving a clean tree" || return 1
}

a_diverged_release_dependency_refuses_to_publish() {
  printf 'local edit\n' >> "$WORK/library/widget/index.js"
  if guard; then log_failure "a diverged dependency stops the publish"; cat "$OUT" >&2; return 1; fi
  log_pass "a diverged dependency stops the publish"
  assert_reports "diverged from its pin" "the report names divergence as the reason" || return 1
  assert_reports "release branch is unchanged" "and says the release branch was left alone"
  git -C "$WORK/library" checkout -- widget/index.js
}

a_missing_sibling_refuses_to_publish() {
  rm "$WORK/library/gadget.widget"
  if guard; then log_failure "a missing sibling stops the publish"; cat "$OUT" >&2; return 1; fi
  log_pass "a missing sibling stops the publish"
  assert_reports "not in place" "the report names the missing sibling as the reason" || return 1
  assert_reports "gadget.widget" "and which one"
  ( cd "$WORK/library" && ln -s widget gadget.widget )
}

a_stale_release_core_is_named_rather_than_worked_around() {
  rm "$WORK/library/release/.suede/core/deps.sh"
  if guard; then log_failure "a core without deps.sh should fail the publish"; return 1; fi
  assert_reports "sync.sh" "the fix (sync the vendored core) is named"
  cp "$ROOT_DIR/dependency/release/core/deps.sh" "$WORK/library/release/.suede/core/deps.sh"
}

run_test_suite --setup setup --cleanup cleanup \
  an_honest_tree_passes_the_guard \
  the_records_are_refreshed_and_committed \
  a_diverged_release_dependency_refuses_to_publish \
  a_missing_sibling_refuses_to_publish \
  a_stale_release_core_is_named_rather_than_worked_around
