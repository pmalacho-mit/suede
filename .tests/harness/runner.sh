TESTS_HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_HARNESS_DIR/color-logging.sh"

run_test() {
  local test_function="$1"
  local test_index="$2"

  log_info "Running test $test_index"
  
  local exit_code=0
  
  # Run the test in a subshell
  # set -e: exit on any error
  # set -u: exit on undefined variable usage
  # set -o pipefail: catch errors in pipelines (not just the last command)
  # Pipe output through sed to indent each line with a tab for better readability
  (set -euo pipefail; $test_function) 2>&1 | sed 's/^/\t/'
  exit_code=${PIPESTATUS[0]}
  
  if [[ $exit_code -eq 0 ]]; then
    log_pass "Test $test_index passed"
    return 0
  else
    log_failure "Test $test_index failed (exit code: $exit_code)"
    return 1
  fi
}

run_test_suite() {
  local setup_function=""
  local cleanup_function=""
  local -a test_functions=()
  
  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case $1 in
      --setup)
        setup_function="$2"
        shift 2
        ;;
      --cleanup)
        cleanup_function="$2"
        shift 2
        ;;
      *)
        test_functions+=("$1")
        shift
        ;;
    esac
  done
  
  # Register cleanup trap if cleanup function provided
  if [[ -n "$cleanup_function" ]]; then
    trap "$cleanup_function" EXIT
  fi
  
  # Run setup if provided
  if [[ -n "$setup_function" ]]; then
    $setup_function
  fi
  
  # Run all tests
  local index=0
  local failed=0
  
  for test_function in "${test_functions[@]}"; do
    run_test "$test_function" $((++index)) || ((failed++))
  done
  
  # Report results
  if [[ $failed -eq 0 ]]; then
    log_success "All tests passed"
    exit 0
  else
    log_error "$failed test(s) failed"
    exit 1
  fi
}