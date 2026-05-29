TESTS_HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_HARNESS_DIR/normalize.sh"
source "$TESTS_HARNESS_DIR/color-logging.sh"

readonly OWNER="pmalacho-mit"
readonly REPO="suede"
readonly FILE="example.txt"

declare -a COMMITS=(
  "c3cb1941a8a58a8bc9dc8d7cfb2f4ceb2af6bed5"
  "8e82606a5ad65022ceebd2076fceaff927125f1c"
)

declare -a FILE_CONTENTS=(
  "first commit"
  "second commit"
)

declare -a GITREPO_CONTENT=(
  "; DO NOT EDIT (unless you know what you are doing)
;

[subrepo]
  remote = https://github.com/${OWNER}/${REPO}.git
  branch = with-single-example-txt-file
  commit = ${COMMITS[0]}
  parent = 
  method = merge"
  "; DO NOT EDIT (unless you know what you are doing)
;[subrepo]
  remote = https://github.com/${OWNER}/${REPO}.git
  branch = with-single-example-txt-file
  commit = ${COMMITS[1]}
  parent = ${COMMITS[0]}
  method = merge"
)

assert_dir_has_expected_contents_for_commit() {
  local dir="$1"
  local index="$2"
  
  local commit="${COMMITS[$index]}"
  local expected_contents="${FILE_CONTENTS[$index]}"
  local file_path="${dir}/${FILE}"
  
  if [[ ! -f "$file_path" ]]; then
    log_error "Expected file '$file_path' does not exist."
    return 1
  fi
  
  local actual_contents="$(strip_cr "$( <"$file_path" )")"
  
  if [[ "$actual_contents" == "$expected_contents" ]]; then
    log_pass "Directory '$dir' has expected contents for commit '$commit'."
    return 0
  else
    log_failure "Directory '$dir' does not have expected contents for commit '$commit'."
    log_info "Expected contents: $expected_contents"
    log_info "Actual contents: $actual_contents"
    return 1
  fi
}

assert_file_has_expected_gitrepo_contents_for_commit() {
  local file_path="$1"
  local index="$2"
  
  local commit="${COMMITS[$index]}"
  local expected_contents="${GITREPO_CONTENT[$index]}"
  
  if [[ ! -f "$file_path" ]]; then
    log_error "Expected .gitrepo file '$file_path' does not exist."
    return 1
  fi
  
  local actual_contents="$(strip_cr "$( <"$file_path" )")"
  
  if [[ "$actual_contents" == "$expected_contents" ]]; then
    log_pass ".gitrepo file '$file_path' has expected contents for commit '$commit'."
    return 0
  else
    log_failure ".gitrepo file '$file_path' does not have expected contents for commit '$commit'."
    log_info "Expected contents: $expected_contents"
    log_info "Actual contents: $actual_contents"
    return 1
  fi
}