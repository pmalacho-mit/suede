#!/usr/bin/env bash
#
# Push git-subrepo directories (after delegating pull to pull.sh).
#
# Usage:
#   ./push.sh [OPTIONS] [TARGET ...]
#
# TARGET is forwarded directly to find.sh and follows find.sh semantics.
# If omitted, find.sh default behavior is used.
#
# Options:
#   --dry, --dry-run          Print the commands that would run without executing them
#   -h, --help                Show this help message

set -euo pipefail

# ----- External Script Dependencies -----
readonly EXTERNAL_SCRIPT_BASE="https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts"
readonly EXTERNAL_SCRIPT_FIND="${EXTERNAL_SCRIPT_BASE}/find.sh"
readonly EXTERNAL_SCRIPT_PULL="${EXTERNAL_SCRIPT_BASE}/pull.sh"

usage() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
  exit 0
}

DRY_RUN=false
declare -a TARGET_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry|--dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    -*)
      printf 'Unknown option: %s\n' "$1" >&2
      exit 1
      ;;
    *)
      TARGET_ARGS+=("$1")
      shift
      ;;
  esac
done

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  printf 'Not inside a git repository.\n' >&2
  exit 1
}

declare -a ALL_DIRS=()
while IFS= read -r abs_dir; do
  [[ -z "$abs_dir" ]] && continue
  [[ "$abs_dir" == "$REPO_ROOT"/* ]] || continue
  ALL_DIRS+=("${abs_dir#"$REPO_ROOT"/}")
done < <(bash <(curl -fsSL "$EXTERNAL_SCRIPT_FIND") "${TARGET_ARGS[@]}")

if [[ ${#ALL_DIRS[@]} -eq 0 ]]; then
  printf 'No subrepos found.\n' >&2
  exit 0
fi

run_cmd() {
  if $DRY_RUN; then
    printf '[dry-run] %s\n' "$*" >&2
  else
    (cd "$REPO_ROOT" && "$@")
  fi
}

declare -a PULL_ARGS=()
$DRY_RUN && PULL_ARGS+=("--dry-run")
PULL_ARGS+=("${TARGET_ARGS[@]}")

if $DRY_RUN; then
  printf '[dry-run] bash <(curl -fsSL %s) %s\n' "$EXTERNAL_SCRIPT_PULL" "${PULL_ARGS[*]-}" >&2
else
  if ! bash <(curl -fsSL "$EXTERNAL_SCRIPT_PULL") "${PULL_ARGS[@]}"; then
    printf 'Pull phase failed; not continuing to push phase.\n' >&2
    exit 1
  fi
fi

for dir in "${ALL_DIRS[@]}"; do
  run_cmd git subrepo push "$dir" || {
    printf 'Push failed for %s\n' "$dir" >&2
    exit 1
  }
done

if $DRY_RUN; then
  printf 'Dry run complete: %d subrepo(s).\n' "${#ALL_DIRS[@]}" >&2
else
  printf 'Pushed %d subrepo(s).\n' "${#ALL_DIRS[@]}" >&2
fi
