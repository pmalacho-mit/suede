#!/usr/bin/env bash
# Offline unit test for extract/subrepo-config.sh — a pure stdin .gitrepo parser
# (no network). Asserts OWNER/REPO/COMMIT extraction across the remote URL shapes
# git-subrepo may record (https, ssh://, scp git@…:), plus .git stripping,
# "last value wins", and error handling for missing fields.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/../.." && pwd)"                 # scripts/
HARNESS="$(cd "$SCRIPTS_DIR/../.tests/harness" && pwd)"
readonly LOCAL_PARSE="$SCRIPTS_DIR/extract/subrepo-config.sh"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"

# A realistic .gitrepo body pointing at <remote> @ <commit>.
gitrepo() { # <remote> <commit>
  printf '; DO NOT EDIT\n;\n[subrepo]\n\tremote = %s\n\tbranch = release\n\tcommit = %s\n\tparent =\n\tmethod = merge\n' \
    "$1" "$2"
}

# Assert the parser emits exactly OWNER/REPO/COMMIT for a given remote shape.
assert_parses() { # <label> <remote> <commit> <want_owner> <want_repo>
  local label="$1" remote="$2" commit="$3" owner="$4" repo="$5" out rc=0 want
  out="$(gitrepo "$remote" "$commit" | bash "$LOCAL_PARSE")" || rc=$?
  want="$(printf 'OWNER=%s\nREPO=%s\nCOMMIT=%s' "$owner" "$repo" "$commit")"
  if [[ $rc -eq 0 && "$out" == "$want" ]]; then log_pass "$label"; return 0; fi
  log_failure "$label"
  log_info "rc=$rc"
  log_info "expected: $(printf '%s' "$want" | tr '\n' '|')"
  log_info "actual:   $(printf '%s' "$out" | tr '\n' '|')"
  return 1
}

# Assert the parser exits non-zero for malformed/incomplete input.
assert_rejects() { # <label> <gitrepo-content>
  local label="$1" content="$2" rc=0
  printf '%s' "$content" | bash "$LOCAL_PARSE" >/dev/null 2>&1 || rc=$?
  if [[ $rc -ne 0 ]]; then log_pass "$label (rc=$rc)"; return 0; fi
  log_failure "$label: expected non-zero exit"; return 1
}

https_remote() {
  assert_parses "https remote" \
    "https://github.com/Owner/my-repo.git" "abc123" "Owner" "my-repo"
}

https_remote_without_git_suffix() {
  assert_parses "https remote without .git" \
    "https://github.com/Owner/my-repo" "abc123" "Owner" "my-repo"
}

ssh_remote() {
  assert_parses "ssh:// remote" \
    "ssh://git@github.com/Owner/my-repo.git" "deadbee" "Owner" "my-repo"
}

scp_remote() {
  assert_parses "scp git@github.com: remote" \
    "git@github.com:Owner/my-repo.git" "deadbee" "Owner" "my-repo"
}

# get_value uses tail -n1, so a later 'commit' line overrides an earlier one.
last_commit_value_wins() {
  local content out
  content="$(printf '[subrepo]\n\tremote = https://github.com/o/r.git\n\tcommit = first\n\tcommit = second\n')"
  out="$(printf '%s' "$content" | bash "$LOCAL_PARSE" | grep '^COMMIT=')"
  if [[ "$out" == "COMMIT=second" ]]; then log_pass "last commit value wins"; return 0; fi
  log_failure "last commit value wins"; log_info "actual: $out"; return 1
}

missing_remote_is_rejected() {
  assert_rejects "missing remote rejected" \
    "$(printf '[subrepo]\n\tcommit = abc123\n')"
}

missing_commit_is_rejected() {
  assert_rejects "missing commit rejected" \
    "$(printf '[subrepo]\n\tremote = https://github.com/o/r.git\n')"
}

non_github_remote_is_rejected() {
  assert_rejects "non-GitHub remote rejected" \
    "$(printf '[subrepo]\n\tremote = https://gitlab.com/o/r.git\n\tcommit = abc\n')"
}

run_test_suite \
  https_remote \
  https_remote_without_git_suffix \
  ssh_remote \
  scp_remote \
  last_commit_value_wins \
  missing_remote_is_rejected \
  missing_commit_is_rejected \
  non_github_remote_is_rejected
