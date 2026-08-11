#!/usr/bin/env bash
# End-to-end suites for scripts/suede.py, reported alongside every other test.
#
# They are plain `unittest` and can be run directly:
#   python3 -m unittest discover .tests/integration -t .tests/integration
# This wrapper exists so one command runs the whole suite and one transcript
# carries the result — a suite you have to remember to run separately is a
# suite that stops being run. Which is also why the modules are discovered
# rather than listed: a hand-kept list is the same problem one level down.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/../.." && pwd)"
HARNESS="$(cd "$ROOT_DIR/.tests/harness" && pwd)"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"
SUITE_DIR="$ROOT_DIR/.tests/integration"

# One harness test per module, so a failure names the area rather than "python".
declare -a MODULES=()
for path in "$SUITE_DIR"/test_*.py; do
  name="$(basename "$path" .py)"
  eval "${name}() { python3 -m unittest discover '$SUITE_DIR' -t '$SUITE_DIR' -p '${name}.py'; }"
  MODULES+=("$name")
done

run_test_suite "${MODULES[@]}"
