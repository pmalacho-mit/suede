#!/usr/bin/env bash
#
# Find git-subrepo directories in the current repository.
#
# Usage:
#   ./find.sh [GLOB]
#
# Arguments:
#   GLOB    Optional glob pattern to filter discovered subrepo directories.
#           Patterns are matched against absolute paths but anchored to the
#           current working directory, so './**' selects every subrepo under
#           the directory from which you invoke the script.
#           Absolute patterns are used as-is.
#
# Output:
#   Absolute paths of subrepo directories (those with a direct .gitrepo
#   child file), one per line, sorted.
#
# Examples:
#   ./find.sh                   # all subrepos in the repo
#   ./find.sh './**'            # subrepos anywhere under the current directory
#   ./find.sh 'sites/*'         # subrepos directly under sites/ (CWD-relative)
#   ./find.sh '/abs/path/**'    # subrepos under an absolute path

set -euo pipefail
shopt -s globstar

GLOB="${1-}"

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
# Resolve the glob to an absolute pattern anchored at CWD
# ---------------------------------------------------------------------------
if [[ -z "$GLOB" ]]; then
  # No glob — default to everything under the current working directory
  abs_pattern="$CWD/**"
elif [[ "$GLOB" == /* ]]; then
  abs_pattern="$GLOB"
else
  # Strip a leading ./ and prepend the absolute CWD
  abs_pattern="$CWD/${GLOB#./}"
fi

# ---------------------------------------------------------------------------
# Find and filter subrepo directories
# ---------------------------------------------------------------------------
while IFS= read -r gitrepo_file; do
  # Resolve to the absolute path of the directory that owns this .gitrepo
  dir="$(cd "$(dirname "$gitrepo_file")" && pwd)"

  echo $dir
  echo $abs_pattern

  # No filter — always emit; otherwise only emit when the path matches
  if [[ "$dir" == $abs_pattern ]]; then
    printf '%s\n' "$dir"
  fi
done < <(find "$REPO_ROOT" -name ".gitrepo" -type f | sort)
