#!/usr/bin/env bash
# Offline test for the install/gitrepo and install/release compatibility path.
#
# Both are argument translators over one real installer, so what is worth
# pinning is the translation: which flags survive, which are dropped, and what
# `suede.py install` is finally asked to do. SUEDE_PY points at a stub that
# records its argv, so no python, network or repository is involved.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
HARNESS="$(cd "$TESTS_DIR/../../.tests/harness" && pwd)"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"

TEST_DIR=""
RECORDED=""

setup() {
  TEST_DIR="$(mktemp -d)"
  RECORDED="$TEST_DIR/argv"
  cat > "$TEST_DIR/stub-suede.py" <<'STUB'
import os, sys
with open(os.environ["SUEDE_TEST_ARGV"], "w") as handle:
    handle.write("\n".join(sys.argv[1:]) + "\n")
STUB
  export SUEDE_PY="file://$TEST_DIR/stub-suede.py"
  export SUEDE_SCRIPT_BASE="file://$SCRIPTS_DIR"
  export SUEDE_TEST_ARGV="$RECORDED"
}

cleanup() {
  [[ -n "${TEST_DIR:-}" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
  unset SUEDE_PY SUEDE_SCRIPT_BASE SUEDE_TEST_ARGV
}

# The stub writes one argument per line; compare against the same shape.
assert_argv() {
  local expected="$1" description="$2"
  local actual; actual="$(cat "$RECORDED")"
  if [[ "$actual" == "$expected" ]]; then
    log_pass "$description"
  else
    log_failure "$description"
    printf 'expected:\n%s\ngot:\n%s\n' "$expected" "$actual" >&2
    return 1
  fi
}

release_passes_repo_through() {
  bash "$SCRIPTS_DIR/install/release.sh" --repo owner/name >/dev/null
  assert_argv "$(printf 'install\n--repo\nowner/name')" "--repo reaches the installer unchanged"
}

release_translates_destination_into_target_and_name() {
  bash "$SCRIPTS_DIR/install/release.sh" -r owner/name -d vendor/dep >/dev/null
  assert_argv "$(printf 'install\n-r\nowner/name\n--name\ndep\n--target\nvendor')" \
    "-d becomes --name plus --target"
}

release_drops_the_v1_metadata_branch_flag() {
  bash "$SCRIPTS_DIR/install/release.sh" --repo owner/name --branch main 2>/dev/null >/dev/null
  assert_argv "$(printf 'install\n--repo\nowner/name')" "--branch main is dropped, not forwarded"
}

release_keeps_commit_suffix() {
  bash "$SCRIPTS_DIR/install/release.sh" --repo owner/name --commit-suffix >/dev/null
  assert_argv "$(printf 'install\n--repo\nowner/name\n--commit-suffix')" \
    "--commit-suffix survives"
}

gitrepo_shim_forwards_the_file_as_a_source() {
  bash "$SCRIPTS_DIR/install/gitrepo.sh" -d vendor/dep example.gitrepo 2>/dev/null >/dev/null
  assert_argv "$(printf 'install\n--name\ndep\n--target\nvendor\n--gitrepo\nexample.gitrepo')" \
    "the positional .gitrepo becomes --gitrepo"
}

gitrepo_shim_announces_that_it_is_deprecated() {
  local output
  output="$(bash "$SCRIPTS_DIR/install/gitrepo.sh" -d dep example.gitrepo 2>&1 >/dev/null)"
  if [[ "$output" == *"deprecated"* ]]; then
    log_pass "the shim says it is deprecated"
  else
    log_failure "the shim says it is deprecated"
    return 1
  fi
}

run_test_suite --setup setup --cleanup cleanup \
  release_passes_repo_through \
  release_translates_destination_into_target_and_name \
  release_drops_the_v1_metadata_branch_flag \
  release_keeps_commit_suffix \
  gitrepo_shim_forwards_the_file_as_a_source \
  gitrepo_shim_announces_that_it_is_deprecated
