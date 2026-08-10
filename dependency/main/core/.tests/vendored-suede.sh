#!/usr/bin/env bash
# `.suede/core/suede.py` is a copy of `scripts/suede.py`, vendored so a
# dependency's CI needs no network to run the guard. A copy that can drift is
# a copy that will, so the drift is a test failure rather than a convention.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/../../../.." && pwd)"
HARNESS="$(cd "$ROOT_DIR/.tests/harness" && pwd)"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"

the_vendored_installer_matches_the_source() {
  if cmp -s "$ROOT_DIR/scripts/suede.py" "$ROOT_DIR/dependency/main/core/suede.py"; then
    log_pass "dependency/main/core/suede.py matches scripts/suede.py"
  else
    log_failure "dependency/main/core/suede.py has drifted from scripts/suede.py"
    printf 'Re-sync it:\n  cp scripts/suede.py dependency/main/core/suede.py\n' >&2
    return 1
  fi
}

run_test_suite the_vendored_installer_matches_the_source
