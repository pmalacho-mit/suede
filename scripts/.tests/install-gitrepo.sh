#!/usr/bin/env bash
# Offline test for install/gitrepo.sh — no network. Its sibling scripts are
# served from the local working copy (SUEDE_SCRIPT_BASE=file://.../scripts) and
# degit's tarball comes from the file:// mirror (GITHUB_API_ORIGIN).
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
HARNESS="$(cd "$TESTS_DIR/../../.tests/harness" && pwd)"
readonly EXTERNAL_INSTALL="https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts/install/gitrepo.sh"
readonly LOCAL_INSTALL="$SCRIPTS_DIR/install/gitrepo.sh"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"
source "$HARNESS/mock-curl.sh"; source "$HARNESS/with-local-suede-chain.sh"

TEST_DIR=""
setup() {
  TEST_DIR="$(mktemp -d)"
  chain_make_offline_origin "$TEST_DIR/origin"
  export SUEDE_SCRIPT_BASE="file://$SCRIPTS_DIR"   # subrepo-config / degit / dependencies, local
  export GITHUB_API_ORIGIN="$CHAIN_API_ORIGIN"     # degit's tarball, local
  mock_curl_url "$EXTERNAL_INSTALL" "$LOCAL_INSTALL"
  enable_url_mocking
}
cleanup() {
  [[ -n "${TEST_DIR:-}" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
  unset SUEDE_SCRIPT_BASE GITHUB_API_ORIGIN; disable_url_mocking
}

installs_referenced_commit_into_destination() {
  local root="$TEST_DIR/case1"; mkdir -p "$root"; cd "$root"   # not a git repo -> empty parent
  local gitrepo="$root/example.gitrepo"; chain_gitrepo_for 0 > "$gitrepo"
  local dest="$root/vendor"
  bash <(curl -fsSL "$EXTERNAL_INSTALL") -d "$dest" "$gitrepo"
  assert_offline_contents "$dest" 0
  assert_file_matches "$dest/.gitrepo" "commit = ${CHAIN_COMMITS[0]}" "installed .gitrepo records the commit"
}

records_parent_when_run_inside_a_repo() {
  local root="$TEST_DIR/case2"; mkdir -p "$root"
  ( cd "$root"; git init --quiet; printf 'x\n' > seed; git add .; git commit --quiet -m seed )
  local parent; parent="$(git -C "$root" rev-parse HEAD)"
  local gitrepo="$root/example.gitrepo"; chain_gitrepo_for 1 > "$gitrepo"
  cd "$root"
  bash <(curl -fsSL "$EXTERNAL_INSTALL") -d "$root/vendor" "$gitrepo"
  assert_offline_contents "$root/vendor" 1
  assert_file_matches "$root/vendor/.gitrepo" "parent = $parent" "installed .gitrepo records the parent HEAD"
}

run_test_suite --setup setup --cleanup cleanup \
  installs_referenced_commit_into_destination \
  records_parent_when_run_inside_a_repo
