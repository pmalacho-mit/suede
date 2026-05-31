#!/usr/bin/env bash
#
# Find git-subrepo directories in the current repository.
#
# Usage:
#   ./find.sh [OPTIONS] [GLOB ...]
#
# Options:
#   --top-level   Emit only "top-level" subrepos: those with no ancestor
#                 directory that is itself a subrepo. A nested .gitrepo (at any
#                 depth beneath another .gitrepo) is omitted, so the first
#                 .gitrepo encountered on a path stops the chain of nesting.
#                 This matters because a nested subrepo was cloned in a
#                 different repository, so the git history its .gitrepo
#                 references does not belong to the current repo and cannot be
#                 pulled/pushed from here.
#
#                 Nesting is resolved entirely in-memory from the single
#                 directory scan (an associative-array membership walk up each
#                 path, using only shell parameter expansion), so the flag adds
#                 no extra filesystem traversal.
#   -h, --help    Show this help message and exit.
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
#   child file), one per line, sorted. With --top-level, subrepos nested
#   inside another subrepo are excluded.
#
# Examples:
#   ./find.sh                     # subrepos under current directory
#   ./find.sh './**'              # subrepos anywhere under the current directory
#   ./find.sh 'sites/*'           # subrepos directly under sites/ (CWD-relative)
#   ./find.sh '/abs/path/**'      # subrepos under an absolute path
#   ./find.sh --top-level './**'  # only non-nested subrepos under CWD
#
# Note:
#   Quote glob patterns to avoid caller-side expansion, e.g. './**' not ./**

set -euo pipefail
shopt -s globstar

usage() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
  exit 0
}

# ---------------------------------------------------------------------------
# Parse options (everything that isn't a recognized flag is a GLOB argument)
# ---------------------------------------------------------------------------
TOP_LEVEL=false
declare -a ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --top-level)
      TOP_LEVEL=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do ARGS+=("$1"); shift; done
      ;;
    -*)
      printf 'Unknown option: %s\n' "$1" >&2
      exit 1
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

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
# Collect every subrepo directory from a single scan. Record each in a set so
# --top-level nesting checks are pure in-memory string lookups (no re-scan).
# ---------------------------------------------------------------------------
declare -A IS_SUBREPO=()
declare -a SUBREPO_DIRS=()
while IFS= read -r gitrepo_file; do
  # Resolve to the absolute path of the directory that owns this .gitrepo
  dir="$(cd "$(dirname "$gitrepo_file")" && pwd)"
  IS_SUBREPO["$dir"]=1
  SUBREPO_DIRS+=("$dir")
done < <(find "$REPO_ROOT" -name ".gitrepo" -type f | sort)

# True when an ancestor directory of $1 is itself a subrepo (i.e. $1 is nested).
# Walks parents via parameter expansion only — no forks, no filesystem access —
# stopping at REPO_ROOT.
is_nested() {
  local p="${1%/*}"
  while [[ -n "$p" && "$p" == "$REPO_ROOT"* ]]; do
    [[ -n "${IS_SUBREPO["$p"]:-}" ]] && return 0
    [[ "$p" == "$REPO_ROOT" ]] && break
    p="${p%/*}"
  done
  return 1
}

# ---------------------------------------------------------------------------
# Emit directories matching a requested pattern (and, with --top-level, that
# are not nested inside another subrepo).
# ---------------------------------------------------------------------------
for dir in ${SUBREPO_DIRS[@]+"${SUBREPO_DIRS[@]}"}; do
  if $TOP_LEVEL && is_nested "$dir"; then
    continue
  fi
  for pattern in "${ABS_PATTERNS[@]}"; do
    if [[ "$dir" == $pattern ]]; then
      printf '%s\n' "$dir"
      break
    fi
  done
done
