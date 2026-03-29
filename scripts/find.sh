#!/usr/bin/env bash
#
# Find git-subrepo directories in the current repository.
#
# Usage:
#   ./find.sh [GLOB ...]
#
# Arguments:
#   GLOB    Optional glob pattern(s) to filter discovered subrepo directories.
#           Patterns are matched against absolute paths but anchored to the
#           current working directory, so './**' selects every subrepo under
#           the directory from which you invoke the script.
#           Absolute patterns are used as-is.
#           If your shell expands globs before invoking this script, expanded
#           paths are still accepted and treated as directory scopes.
#
# Output:
#   Absolute paths of subrepo directories (those with a direct .gitrepo
#   child file), one per line, sorted.
#
# Examples:
#   ./find.sh                   # subrepos under current directory
#   ./find.sh './**'            # subrepos anywhere under the current directory
#   ./find.sh 'sites/*'         # subrepos directly under sites/ (CWD-relative)
#   ./find.sh '/abs/path/**'    # subrepos under an absolute path
#
# Note:
#   Quote glob patterns to avoid caller-side expansion, e.g. './**' not ./**

set -euo pipefail
shopt -s globstar

# ---------------------------------------------------------------------------
# Identify repo root
# ---------------------------------------------------------------------------
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  printf 'Not inside a git repository.\n' >&2
  exit 1
}

# Capture CWD before any directory changes so glob anchoring is correct.
CWD="$PWD"

# ---------------------------------------------------------------------------
# Resolve arguments to absolute filter patterns
# ---------------------------------------------------------------------------
has_glob_meta() {
  local s="$1"
  [[ "$s" == *'*'* || "$s" == *'?'* || "$s" == *'['* ]]
}

to_abs_pattern() {
  local raw="$1"

  # Treat plain directory paths (including ".") as subtree scopes.
  if ! has_glob_meta "$raw"; then
    local maybe_dir
    if [[ "$raw" == /* ]]; then
      maybe_dir="$raw"
    else
      maybe_dir="$CWD/$raw"
    fi

    if [[ -d "$maybe_dir" ]]; then
      maybe_dir="$(cd "$maybe_dir" && pwd)"
      printf '%s\n' "$maybe_dir/**"
      return
    fi
  fi

  # Otherwise interpret as a glob pattern (absolute or CWD-relative).
  if [[ "$raw" == /* ]]; then
    printf '%s\n' "$raw"
  else
    printf '%s\n' "$CWD/${raw#./}"
  fi
}

declare -a ABS_PATTERNS=()

if [[ $# -eq 0 ]]; then
  # No argument: search only under current working directory.
  ABS_PATTERNS+=("$CWD/**")
else
  for arg in "$@"; do
    ABS_PATTERNS+=("$(to_abs_pattern "$arg")")
  done
fi

# ---------------------------------------------------------------------------
# Find and filter subrepo directories
# ---------------------------------------------------------------------------
while IFS= read -r gitrepo_file; do
  # Resolve to the absolute path of the directory that owns this .gitrepo
  dir="$(cd "$(dirname "$gitrepo_file")" && pwd)"

  # Emit when this directory matches any resolved pattern.
  for pattern in "${ABS_PATTERNS[@]}"; do
    if [[ "$dir" == $pattern ]]; then
      printf '%s\n' "$dir"
      break
    fi
  done
done < <(find "$REPO_ROOT" -name ".gitrepo" -type f | sort)
