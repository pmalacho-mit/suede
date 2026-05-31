#!/usr/bin/env bash
# Offline unit test for populate/readme-after-init.sh — generates the root
# README install instructions from the git 'origin' remote (no network). Covers
# the remote URL shapes it parses (https, scp git@…:, ssh://, http, missing
# .git) and the repo-name humanizer, plus the missing-origin error path.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/../.." && pwd)"                 # scripts/
HARNESS="$(cd "$SCRIPTS_DIR/../.tests/harness" && pwd)"
readonly LOCAL_GEN="$SCRIPTS_DIR/populate/readme-after-init.sh"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"

TMP=""
setup()   { TMP="$(mktemp -d)"; }
cleanup() { [[ -n "${TMP:-}" && -d "$TMP" ]] && rm -rf "$TMP"; }

# Create a repo named <dirname> with origin=<url>, run the generator inside it,
# and echo the resulting README.md.
gen_readme() { # <dirname> <origin-url>
  local dir="$TMP/$1" url="$2"
  rm -rf "$dir"; git init --quiet "$dir"
  ( cd "$dir"
    git remote add origin "$url"
    bash "$LOCAL_GEN" >/dev/null 2>&1
    cat README.md )
}

assert_readme_has() { # <label> <readme> <ere>
  if grep -qE -- "$3" <<<"$2"; then log_pass "$1"; return 0; fi
  log_failure "$1"; log_info "missing /$3/ in:"; printf '%s\n' "$2" | sed 's/^/    /'; return 1
}

# Each remote shape must yield the same repo id (Owner/my-repo) and release URL.
remote_shape_https() {
  local r; r="$(gen_readme my-repo "https://github.com/Owner/my-repo.git")"
  assert_readme_has "https: --repo id"     "$r" '--repo Owner/my-repo' &&
  assert_readme_has "https: release URL"   "$r" 'https://github\.com/Owner/my-repo/tree/release'
}

remote_shape_https_no_git_suffix() {
  local r; r="$(gen_readme my-repo "https://github.com/Owner/my-repo")"
  assert_readme_has "https no .git: --repo id" "$r" '--repo Owner/my-repo'
}

remote_shape_scp() {
  local r; r="$(gen_readme my-repo "git@github.com:Owner/my-repo.git")"
  assert_readme_has "scp: --repo id"   "$r" '--repo Owner/my-repo' &&
  assert_readme_has "scp: release URL" "$r" 'https://github\.com/Owner/my-repo/tree/release'
}

remote_shape_ssh() {
  local r; r="$(gen_readme my-repo "ssh://git@github.com/Owner/my-repo.git")"
  assert_readme_has "ssh: --repo id"   "$r" '--repo Owner/my-repo' &&
  assert_readme_has "ssh: release URL" "$r" 'https://github\.com/Owner/my-repo/tree/release'
}

# The H1 title humanizes the repo folder name: '-' and '_' become spaces, then
# each word is Title Cased.
humanizer_hyphens_and_underscores() {
  local r
  r="$(gen_readme my-cool-repo "https://github.com/Owner/my-cool-repo.git")"
  assert_readme_has "hyphens -> 'My Cool Repo'" "$r" '^# My Cool Repo$' || return 1
  r="$(gen_readme my_cool_repo "https://github.com/Owner/my_cool_repo.git")"
  assert_readme_has "underscores -> 'My Cool Repo'" "$r" '^# My Cool Repo$'
}

missing_origin_is_rejected() {
  local dir="$TMP/no-origin" rc=0
  rm -rf "$dir"; git init --quiet "$dir"
  ( cd "$dir" && bash "$LOCAL_GEN" ) >/dev/null 2>&1 || rc=$?
  if [[ $rc -ne 0 ]]; then log_pass "missing origin -> non-zero exit (rc=$rc)"; return 0; fi
  log_failure "missing origin should exit non-zero"; return 1
}

run_test_suite --setup setup --cleanup cleanup \
  remote_shape_https \
  remote_shape_https_no_git_suffix \
  remote_shape_scp \
  remote_shape_ssh \
  humanizer_hyphens_and_underscores \
  missing_origin_is_rejected
