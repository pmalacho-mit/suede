#!/usr/bin/env bash
# The pure suites for scripts/suede.py, reported alongside every other test.
#
# They are plain `unittest` and can be run directly:
#   python3 -m unittest discover .tests/unit -t .tests/unit
# This wrapper exists so one command runs the whole suite and one transcript
# carries the result — a suite you have to remember to run separately is a
# suite that stops being run.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/../.." && pwd)"
HARNESS="$(cd "$ROOT_DIR/.tests/harness" && pwd)"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"

# One harness test per module, so a failure names the area rather than "python".
module() {
  python3 -m unittest discover "$ROOT_DIR/.tests/unit" -t "$ROOT_DIR/.tests/unit" -p "$1.py"
}

planner_scenarios()      { module test_planner; }
check_and_classification() { module test_check; }
the_pure_boundary()      { module test_purity; }

run_test_suite planner_scenarios check_and_classification the_pure_boundary
