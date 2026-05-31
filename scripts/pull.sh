#!/usr/bin/env bash
#
# Pull git-subrepo directories.
#
# Usage:
#   ./pull.sh [OPTIONS] [TARGET ...]
#
# TARGET is forwarded directly to find.sh and follows find.sh semantics.
# If omitted, find.sh default behavior is used.
#
# Only top-level subrepos are pulled: find.sh is invoked with --top-level, so a
# .gitrepo nested (at any depth) inside a folder that itself contains a .gitrepo
# is excluded. Nested subrepos were cloned in a different repository, so the git
# history their .gitrepo references does not belong to this consuming repo and
# `git subrepo pull` cannot resolve it. (The first .gitrepo on a path stops the
# chain of nesting.)
#
# Options:
#   --dry, --dry-run          Print the commands that would run without executing them
#   -h, --help                Show this help message

set -euo pipefail

# ----- External Script Dependencies -----
readonly EXTERNAL_SCRIPT_BASE="https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts"
readonly EXTERNAL_SCRIPT_FIND="${EXTERNAL_SCRIPT_BASE}/find.sh"

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

# --top-level excludes subrepos nested inside another subrepo (see find.sh).
declare -a DIRS=()
while IFS= read -r abs_dir; do
  [[ -z "$abs_dir" ]] && continue
  [[ "$abs_dir" == "$REPO_ROOT"/* ]] || continue
  DIRS+=("${abs_dir#"$REPO_ROOT"/}")
done < <(bash <(curl -fsSL "$EXTERNAL_SCRIPT_FIND") --top-level ${TARGET_ARGS[@]+"${TARGET_ARGS[@]}"})

if [[ ${#DIRS[@]} -eq 0 ]]; then
  printf 'No top-level subrepos found.\n' >&2
  exit 0
fi

run_cmd() {
  if $DRY_RUN; then
    printf '[dry-run] %s\n' "$*" >&2
  else
    (cd "$REPO_ROOT" && "$@")
  fi
}

for dir in "${DIRS[@]}"; do
  run_cmd git subrepo pull "$dir" || {
    printf 'Pull failed for %s\n' "$dir" >&2
    exit 1
  }
done

if $DRY_RUN; then
  printf 'Dry run complete: %d subrepo(s).\n' "${#DIRS[@]}" >&2
else
  printf 'Pulled %d subrepo(s).\n' "${#DIRS[@]}" >&2
fi
