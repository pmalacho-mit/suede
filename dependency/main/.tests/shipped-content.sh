#!/usr/bin/env bash
# What ships, and what must not.
#
# Every directory under dependency/ holding a .gitrepo is pushed to a branch of
# this library and vendored into consumers as .suede/core (or .github/workflows).
# Whatever sits in one of those directories goes out with it, which makes both
# of these assertions about the same thing: the shipped payload is exactly what
# we meant to ship, no more and no less.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/../../.." && pwd)"
HARNESS="$(cd "$ROOT_DIR/.tests/harness" && pwd)"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"

shipped_directories() {
  find "$ROOT_DIR/dependency" -name .gitrepo -not -path '*/.git/*' \
    | sed 's#/\.gitrepo$##' | sort
}

# The installer is vendored so a dependency's CI runs the guard without
# reaching the network. A copy that can drift is a copy that will.
the_vendored_installer_matches_the_source() {
  if cmp -s "$ROOT_DIR/scripts/suede.py" "$ROOT_DIR/dependency/main/core/suede.py"; then
    log_pass "dependency/main/core/suede.py matches scripts/suede.py"
  else
    log_failure "dependency/main/core/suede.py has drifted from scripts/suede.py"
    printf 'Re-sync it:\n  cp scripts/suede.py dependency/main/core/suede.py\n' >&2
    return 1
  fi
}

# Tests belong beside the subrepo, not inside it: dependency/main/.tests is
# discovered by this harness and pushed nowhere.
no_tests_ship_inside_a_subrepo() {
  local offenders=""
  local directory
  while IFS= read -r directory; do
    local found
    found="$(find "$directory" -type d -name .tests -not -path '*/.git/*' || true)"
    [[ -n "$found" ]] && offenders+="$found"$'\n'
  done < <(shipped_directories)

  if [[ -z "${offenders//[[:space:]]/}" ]]; then
    log_pass "no test directories inside a shipped subrepo"
  else
    log_failure "these would ship to every consumer:"
    printf '%s' "$offenders" >&2
    printf 'Move them beside the subrepo instead (e.g. dependency/main/.tests/).\n' >&2
    return 1
  fi
}

run_test_suite the_vendored_installer_matches_the_source no_tests_ship_inside_a_subrepo
