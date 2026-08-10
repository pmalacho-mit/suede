#!/usr/bin/env bash
# End-to-end installs and context resolution against real local repositories.
#
#   python3 -m unittest discover .tests/integration -t .tests/integration
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/../.." && pwd)"
HARNESS="$(cd "$ROOT_DIR/.tests/harness" && pwd)"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"

module() {
  python3 -m unittest discover "$ROOT_DIR/.tests/integration" -t "$ROOT_DIR/.tests/integration" -p "$1.py"
}

installing_into_a_real_repository() { module test_install; }
resolving_repo_and_separator()      { module test_context; }

run_test_suite installing_into_a_real_repository resolving_repo_and_separator
