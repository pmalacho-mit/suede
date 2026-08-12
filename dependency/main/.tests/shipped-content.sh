#!/usr/bin/env bash
# What ships, and what must not.
#
# Every directory under dependency/ holding a .gitrepo is pushed to a branch of
# this library and vendored into consumers as .suede/core (or .github/workflows).
# Whatever sits in one of those directories goes out with it, so both assertions
# here are about the same thing: the shipped payload is exactly what we meant to
# ship, no more and no less.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/../../.." && pwd)"
HARNESS="$(cd "$ROOT_DIR/.tests/harness" && pwd)"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"

shipped_directories() {
  find "$ROOT_DIR/dependency" -name .gitrepo -not -path '*/.git/*' \
    | sed 's#/\.gitrepo$##' | sort
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

# A core folder is a dependency's whole view of suede's tooling: its README is
# the only place the scripts are explained, and it is read from inside the
# consumer's repo where the library is not to hand. A script nobody documented
# is a script nobody runs.
every_core_script_is_documented() {
  local undocumented=""
  local core script name
  for core in "$ROOT_DIR"/dependency/*/core; do
    # Everything in the folder, not a list of extensions: `sync` and `upstream`
    # ship without one, and a check that has to be remembered is a check that
    # goes stale.
    for script in "$core"/* ; do
      [[ -f "$script" ]] || continue
      name="$(basename "$script")"
      [[ "$name" == "README.md" || "$name" == ".gitrepo" ]] && continue
      grep -q -- "$name" "$core/README.md" 2>/dev/null || undocumented+="${core#$ROOT_DIR/}/$name"$'\n'
    done
  done

  if [[ -z "${undocumented//[[:space:]]/}" ]]; then
    log_pass "every core script is named in its README"
  else
    log_failure "these ship with no explanation in their folder's README:"
    printf '%s' "$undocumented" >&2
    return 1
  fi
}

run_test_suite no_tests_ship_inside_a_subrepo every_core_script_is_documented
