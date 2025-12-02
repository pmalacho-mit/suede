set -euo pipefail

SCRIPTS_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_HARNESS_DIR="$(cd "$SCRIPTS_TESTS_DIR/../../.tests/harness" && pwd)"

readonly EXTERNAL_SCRIPT_INSTALL="https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts/install-subrepo-dependency.sh"
readonly LOCAL_SCRIPT_INSTALL="$SCRIPTS_TESTS_DIR/../install-subrepo-dependency.sh"

readonly EXTERNAL_SCRIPT_EXTRACT="https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts/extract-subrepo-config.sh"
readonly LOCAL_SCRIPT_EXTRACT="$SCRIPTS_TESTS_DIR/../extract-subrepo-config.sh"

readonly EXTERNAL_SCRIPT_DEGIT="https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts/utils/degit.sh"
readonly LOCAL_SCRIPT_DEGIT="$SCRIPTS_TESTS_DIR/../utils/degit.sh"

source "$TEST_HARNESS_DIR/runner.sh"
source "$TEST_HARNESS_DIR/color-logging.sh"
source "$TEST_HARNESS_DIR/mock-curl.sh"
source "$TEST_HARNESS_DIR/normalize.sh"
source "$TEST_HARNESS_DIR/with-single-example-txt-file.sh"

TEST_DIR=""

setup_test_env() {
  TEST_DIR="$(mktemp -d)"
  log_info "Created test directory: $TEST_DIR"

  mock_curl_url "$EXTERNAL_SCRIPT_INSTALL" "$LOCAL_SCRIPT_INSTALL"
  mock_curl_url "$EXTERNAL_SCRIPT_EXTRACT" "$LOCAL_SCRIPT_EXTRACT"
  mock_curl_url "$EXTERNAL_SCRIPT_DEGIT" "$LOCAL_SCRIPT_DEGIT"

  enable_url_mocking
  log_success "Test environment set up"
}

cleanup_test_env() {
  if [[ -n "${TEST_DIR:-}" && -d "$TEST_DIR" ]]; then
    rm -rf "$TEST_DIR"
    log_info "Cleaned up test directory"
  fi
  disable_url_mocking
}

only_positional_argument() {
  local destination="${TEST_DIR}/only-positional-argument"
  local file_path="${destination}/example.gitrepo"
  local gitrepo_content="${GITREPO_CONTENT[0]}"
  mkdir -p "$destination"
  printf "%s" "$gitrepo_content" > "$file_path"
  bash <(curl -fsSL $EXTERNAL_SCRIPT_INSTALL) "$file_path"
  assert_dir_has_expected_contents_for_commit "$destination/example" 0
  assert_file_has_expected_gitrepo_contents_for_commit "$file_path" 0
}

with_destination() {
  local root="${TEST_DIR}/with-destination"
  local file_path="${root}/example.gitrepo"
  local destination="${root}/subdir"
  local gitrepo_content="${GITREPO_CONTENT[0]}"
  mkdir -p "$root"
  printf "%s" "$gitrepo_content" > "$file_path"
  bash <(curl -fsSL $EXTERNAL_SCRIPT_INSTALL) "$file_path" --destination "$destination"
  assert_dir_has_expected_contents_for_commit "$destination" 0
}

run_test_suite \
  --setup setup_test_env \
  --cleanup cleanup_test_env \
  only_positional_argument \
  with_destination 