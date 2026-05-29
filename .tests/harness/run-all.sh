#!/usr/bin/env bash
# Test-suite orchestrator.
#
# Discovers every test file (a *.sh living directly inside a `.tests/`
# directory) and runs each one in isolation, then prints a compact summary.
#
# Design notes (why this is shaped the way it is):
#   * Each test's stdout+stderr is redirected to its OWN log FILE — never a
#     pipe and never command substitution `$(…)`. The git-subrepo-heavy tests
#     spawn children and manipulate file descriptors; isolating each test to a
#     file keeps that activity from interfering with the orchestrator.
#   * Tests get `</dev/null` for stdin, so none can drain a shared descriptor.
#   * Everything the orchestrator prints is ALSO appended to a transcript file
#     in $SUEDE_TEST_LOGDIR. Docker can drop a container's buffered stdout when
#     PID 1 exits (no TTY), so streamed stdout is best-effort only — run.sh
#     reads the transcript file from the host as the source of truth.
#   * We do NOT use `set -e`; exit codes are handled explicitly so one failing
#     test never aborts the run.
#
# Output: one status line per test (quiet mode), or full per-test output with
# SUEDE_TEST_VERBOSE=1 / --verbose. Exit code is 0 iff every test passed.
#
# Usage:
#   run-all.sh [--verbose] [name ...]    # no names = run all discovered tests

set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HARNESS_DIR/../.." && pwd)"
source "$HARNESS_DIR/color-logging.sh"

VERBOSE="${SUEDE_TEST_VERBOSE:-0}"
declare -a NAME_FILTERS=()
for arg in "$@"; do
  case "$arg" in
    --verbose|-v) VERBOSE=1 ;;
    *) NAME_FILTERS+=("$arg") ;;
  esac
done

# Per-test logs and the transcript live here. run.sh points this at a mounted
# directory so the host can read complete results regardless of stdout.
LOG_DIR="${SUEDE_TEST_LOGDIR:-$(mktemp -d)}"
mkdir -p "$LOG_DIR"
TRANSCRIPT="$LOG_DIR/transcript.log"
: > "$TRANSCRIPT"

# Remove ANSI colour codes. Live terminal output keeps colour; the files on
# disk are plain text so they read cleanly in an editor.
ESC="$(printf '\033')"
strip_ansi() { sed "s/${ESC}\[[0-9;]*m//g"; }

# say: print a line to stdout in colour (best-effort, live) AND append a
# colour-stripped copy to the transcript (the authoritative result the host
# reads back).
say() { printf '%b\n' "$*"; printf '%b\n' "$*" | strip_ansi >> "$TRANSCRIPT"; }

# --- discovery --------------------------------------------------------------
# A test file is a *.sh whose immediate parent directory is named `.tests` —
# i.e. a test colocated with the source it covers (scripts/**/.tests/*.sh).
# The suite's own top-level `.tests/` dir holds harness + the launcher, not
# tests, so it is excluded (otherwise `.tests/run.sh` would be run as a "test").
discover_tests() {
  find "$ROOT_DIR" -type f -path '*/.tests/*.sh' \
    | awk -F/ -v infra="$ROOT_DIR/.tests" '
        $(NF-1)==".tests" {
          dir=$0; sub(/\/[^/]*$/, "", dir)   # the file'\''s directory
          if (dir != infra) print
        }' \
    | sort
}

# Keep only tests whose basename matches one of the user-supplied filters.
matches_filter() {
  [[ ${#NAME_FILTERS[@]} -eq 0 ]] && return 0
  local base; base="$(basename "$1")"
  local f
  for f in "${NAME_FILTERS[@]}"; do
    [[ "$base" == "$f" || "$base" == "$f.sh" ]] && return 0
  done
  return 1
}

# --- per-test counts (best-effort, from the runner's own log lines) ---------
# The shared runner prints "Running test N" / "Test N passed"; counting those
# gives an accurate "passed/total" without parsing assertion lines.
count_in_log() { grep -cE "$1" "$2" 2>/dev/null || true; }

# --- run one test -----------------------------------------------------------
run_one() {
  local file="$1" name log rc total passed
  name="$(basename "$file")"
  log="$LOG_DIR/$name.log"

  [[ -x "$file" ]] || chmod +x "$file" 2>/dev/null || true

  # The whole point: output to a file, stdin from /dev/null — no pipe shared
  # with this orchestrator.
  bash "$file" </dev/null >"$log" 2>&1
  rc=$?

  # Plain-text logs on disk (colour only matters on a live terminal).
  strip_ansi <"$log" >"$log.tmp" && mv "$log.tmp" "$log"

  total="$(count_in_log 'Running test [0-9]+' "$log")"
  passed="$(count_in_log 'Test [0-9]+ passed' "$log")"

  if [[ $rc -eq 0 ]]; then
    say "$(printf '%b ✓ %-26s%b %b(%s/%s)%b' \
      "$GREEN" "$name" "$NO_COLOR" "$GREEN" "$passed" "$total" "$NO_COLOR")"
    [[ "$VERBOSE" == "1" ]] && { say "$(sed 's/^/      /' "$log")"; }
  else
    say "$(printf '%b ✗ %-26s%b %b(%s/%s, exit %d)%b' \
      "$RED" "$name" "$NO_COLOR" "$RED" "$passed" "$total" "$rc" "$NO_COLOR")"
    # Reveal the failing test's full log, indented.
    say "$(sed 's/^/      /' "$log")"
  fi
  return $rc
}

# --- main -------------------------------------------------------------------
mapfile -t TESTS < <(discover_tests)

declare -a SELECTED=()
for t in "${TESTS[@]}"; do
  matches_filter "$t" && SELECTED+=("$t")
done

if [[ ${#SELECTED[@]} -eq 0 ]]; then
  say "$(printf '%b[ERROR]%b No test files found' "$RED" "$NO_COLOR")"
  exit 1
fi

say ""
say "Running ${#SELECTED[@]} test file(s)…"
say ""

declare -a PASSED=() FAILED=()
for t in "${SELECTED[@]}"; do
  if run_one "$t"; then PASSED+=("$(basename "$t")"); else FAILED+=("$(basename "$t")"); fi
done

# --- summary ----------------------------------------------------------------
total=${#SELECTED[@]}
say ""
say "──────────────────────────────────────────────"
say "$(printf '  %-8s %d' 'Total:'  "$total")"
say "$(printf '  %b%-8s %d%b' "$GREEN" 'Passed:' "${#PASSED[@]}" "$NO_COLOR")"
say "$(printf '  %b%-8s %d%b' "$RED"   'Failed:' "${#FAILED[@]}" "$NO_COLOR")"
say "──────────────────────────────────────────────"

if [[ ${#FAILED[@]} -gt 0 ]]; then
  say ""
  say "$(printf '%bFailed:%b' "$RED" "$NO_COLOR")"
  for f in "${FAILED[@]}"; do say "$(printf '  %b✗%b %s' "$RED" "$NO_COLOR" "$f")"; done
  say ""
  exit 1
fi

say ""
say "$(printf '%bAll %d test file(s) passed ✓%b' "$GREEN" "$total" "$NO_COLOR")"
say ""
exit 0
