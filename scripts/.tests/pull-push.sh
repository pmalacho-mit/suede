#!/usr/bin/env bash
# Offline test for pull.sh / push.sh and the shared helpers.sh they source.
# Runs both entrypoints in --dry-run mode, so no real network and no
# `git subrepo` ever runs. SUEDE_SCRIPT_BASE points them at a file:// mirror of
# the scripts dir, so they source the real helpers.sh and fetch the real find.sh
# from local disk — exercising the actual sourcing/curl plumbing offline.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"                  # scripts/
HARNESS="$(cd "$SCRIPTS_DIR/../.tests/harness" && pwd)"
readonly LOCAL_PULL="$SCRIPTS_DIR/pull.sh"
readonly LOCAL_PUSH="$SCRIPTS_DIR/push.sh"
readonly BASE="file://$SCRIPTS_DIR"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"

# A repo with two top-level subrepos (a, b), one nested (a/nested) that
# --top-level must exclude, and a plain dir that is never a subrepo.
REPO=""
setup() {
  REPO="$(mktemp -d)"
  git -C "$REPO" init --quiet
  local d
  for d in a a/nested b plain; do mkdir -p "$REPO/$d"; done
  for d in a a/nested b; do printf '[subrepo]\n' > "$REPO/$d/.gitrepo"; done
  printf 'x\n' > "$REPO/plain/file.txt"
}
cleanup() { [[ -n "${REPO:-}" && -d "$REPO" ]] && rm -rf "$REPO"; }

# Run an entrypoint inside <dir> with the file:// mirror; merge stdout+stderr.
run_in() { # <dir> <script> [args...]
  local dir="$1" script="$2"; shift 2
  ( cd "$dir" && SUEDE_SCRIPT_BASE="$BASE" bash "$script" "$@" ) 2>&1
}

assert_contains() { # <label> <haystack> <ere>
  if grep -qE -- "$3" <<<"$2"; then log_pass "$1"; return 0; fi
  log_failure "$1"; log_info "missing /$3/ in:"; printf '%s\n' "$2" | sed 's/^/    /'; return 1
}
assert_absent() { # <label> <haystack> <ere>
  if grep -qE -- "$3" <<<"$2"; then
    log_failure "$1"; log_info "unexpected /$3/ in:"; printf '%s\n' "$2" | sed 's/^/    /'; return 1
  fi
  log_pass "$1"; return 0
}

# pull --dry-run: emits a `git subrepo pull` per TOP-LEVEL subrepo (a, b only),
# never the nested one, and a 2-count summary.
pull_dry_run_is_top_level_only() {
  local out; out="$(run_in "$REPO" "$LOCAL_PULL" --dry-run)"
  assert_contains "pull: dry-run on a"          "$out" '\[dry-run\] git subrepo pull a$' &&
  assert_contains "pull: dry-run on b"          "$out" '\[dry-run\] git subrepo pull b$' &&
  assert_absent   "pull: nested a/nested absent" "$out" 'a/nested' &&
  assert_contains "pull: 2-subrepo summary"     "$out" 'Dry run complete: 2 subrepo\(s\)\.'
}

# push --dry-run: forwards --dry-run to the delegated pull phase, then emits a
# `git subrepo push` per top-level subrepo with a matching summary.
push_dry_run_forwards_pull_and_is_top_level_only() {
  local out; out="$(run_in "$REPO" "$LOCAL_PUSH" --dry-run)"
  assert_contains "push: forwards --dry-run to pull phase" "$out" '\[dry-run\] bash <\(curl.*pull\.sh\) --dry-run' &&
  assert_contains "push: dry-run on a"          "$out" '\[dry-run\] git subrepo push a$' &&
  assert_contains "push: dry-run on b"          "$out" '\[dry-run\] git subrepo push b$' &&
  assert_absent   "push: nested a/nested absent" "$out" 'a/nested' &&
  assert_contains "push: 2-subrepo summary"     "$out" 'Dry run complete: 2 subrepo\(s\)\.'
}

# An empty repo reports none and exits 0 (helpers' subrepo_collect_dirs path).
empty_repo_reports_none() {
  local empty out rc=0
  empty="$(mktemp -d)"; git -C "$empty" init --quiet
  out="$(run_in "$empty" "$LOCAL_PULL" --dry-run)" || rc=$?
  rm -rf "$empty"
  if [[ $rc -eq 0 ]] && grep -q 'No top-level subrepos found' <<<"$out"; then
    log_pass "empty repo: reports none, exit 0"; return 0
  fi
  log_failure "empty repo"; log_info "rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; return 1
}

# --help is handled by the entrypoint usage() (called from helpers' parser).
help_prints_usage_exit_zero() {
  local out rc=0
  out="$(run_in "$REPO" "$LOCAL_PULL" --help)" || rc=$?
  if [[ $rc -eq 0 ]] && grep -q 'Usage:' <<<"$out"; then
    log_pass "pull --help prints usage, exit 0"; return 0
  fi
  log_failure "pull --help"; log_info "rc=$rc"; printf '%s\n' "$out" | sed 's/^/    /'; return 1
}

unknown_option_is_rejected() {
  local rc=0
  run_in "$REPO" "$LOCAL_PULL" --bogus >/dev/null 2>&1 || rc=$?
  if [[ $rc -ne 0 ]]; then log_pass "pull rejects unknown option (rc=$rc)"; return 0; fi
  log_failure "pull should reject --bogus"; return 1
}

run_test_suite --setup setup --cleanup cleanup \
  pull_dry_run_is_top_level_only \
  push_dry_run_forwards_pull_and_is_top_level_only \
  empty_repo_reports_none \
  help_prints_usage_exit_zero \
  unknown_option_is_rejected
