#!/usr/bin/env bash
# The publish guard, against real local repositories.
#
# What is worth pinning here is the refusal: a release dependency ships as a
# pointer, so a diverged dependency or an implicitly-resolved edge must stop
# the publish rather than send a lie out to consumers. Those cases stop before
# the remote is touched, so they need no git-subrepo; only the happy path does.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$TESTS_DIR/../core" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/../../.." && pwd)"
HARNESS="$(cd "$ROOT_DIR/.tests/harness" && pwd)"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"

readonly PUSH_RELEASE="$CORE_DIR/push-release.sh"

TEST_DIR=""
LIBRARY=""

# One dependency (`widget`) published on a release branch, and a library that
# declares it as a release dependency of its own.
setup() {
  TEST_DIR="$(mktemp -d)"
  LIBRARY="$TEST_DIR/library"
  WIDGET_REMOTE="$(python3 - "$TEST_DIR" <<'PY'
import sys
sys.path.insert(0, __import__("os").environ["SUEDE_FIXTURES"])
import make_graph
nodes = make_graph.build({"widget": {}}, sys.argv[1])
library = make_graph.consumer(sys.argv[1], name="library", release=True)
print(nodes["widget"].remote)
PY
)"
  ( cd "$LIBRARY" && python3 "$ROOT_DIR/scripts/suede.py" install --repo "$WIDGET_REMOTE" --yes >/dev/null )
  ( cd "$LIBRARY" && git commit --quiet -am "install widget" )
}

cleanup() { [[ -n "${TEST_DIR:-}" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"; }

# DRY_RUN stops after the guard, which is everything these cases are about.
guard() {
  ( cd "$LIBRARY" && DRY_RUN=1 SUEDE="$ROOT_DIR/scripts/suede.py" bash "$PUSH_RELEASE" ) \
    > "$TEST_DIR/out.txt" 2>&1
}

assert_reports() {
  local needle="$1" description="$2"
  if grep -q -- "$needle" "$TEST_DIR/out.txt"; then
    log_pass "$description"
  else
    log_failure "$description"; cat "$TEST_DIR/out.txt" >&2; return 1
  fi
}

an_honest_tree_passes_the_guard() {
  guard || { log_failure "guard passed on a clean tree"; cat "$TEST_DIR/out.txt" >&2; return 1; }
  log_pass "guard passed on a clean tree"
}

the_manifest_is_refreshed_from_the_tree() {
  guard || true
  [[ -f "$LIBRARY/release/.suede/.dependencies/library.widget.gitrepo" ]] \
    || { log_failure "extract recorded the release dependency"; return 1; }
  log_pass "extract recorded the release dependency"
}

a_shipped_record_carries_no_local_bookkeeping() {
  guard || true
  local record="$LIBRARY/release/.suede/.dependencies/library.widget.gitrepo"
  if git config -f "$record" --get subrepo.parent >/dev/null 2>&1; then
    log_failure "the shipped record omits parent"; return 1
  fi
  log_pass "the shipped record omits parent"
}

a_diverged_release_dependency_refuses_to_publish() {
  printf 'local edit\n' >> "$LIBRARY/library.widget/index.ts"
  if guard; then
    log_failure "a diverged dependency stops the publish"; cat "$TEST_DIR/out.txt" >&2; return 1
  fi
  log_pass "a diverged dependency stops the publish"
  assert_reports "diverged" "the report names divergence as the reason"
}

an_undeclared_edge_refuses_to_publish() {
  # A sibling satisfying widget's edge that no root entry declares: exactly the
  # implicit dependency the flattening rule exists to prevent.
  mkdir -p "$LIBRARY/library.widget/.suede/.dependencies"
  printf '[subrepo]\n\tremote = %s\n\tbranch = release\n\tcommit = %s\n' \
    "https://example.test/ghost" "$(printf '0%.0s' {1..40})" \
    > "$LIBRARY/library.widget/.suede/.dependencies/widget.ghost.gitrepo"
  if guard; then
    log_failure "an undeclared edge stops the publish"; cat "$TEST_DIR/out.txt" >&2; return 1
  fi
  log_pass "an undeclared edge stops the publish"
  assert_reports "check failed" "the report names check as the reason"
}

export SUEDE_FIXTURES="$ROOT_DIR/.tests/fixtures"

run_test_suite --setup setup --cleanup cleanup \
  an_honest_tree_passes_the_guard \
  the_manifest_is_refreshed_from_the_tree \
  a_shipped_record_carries_no_local_bookkeeping \
  a_diverged_release_dependency_refuses_to_publish \
  an_undeclared_edge_refuses_to_publish
