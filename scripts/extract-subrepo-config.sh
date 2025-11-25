#!/usr/bin/env bash
# Parse a git-subrepo .gitrepo file and output OWNER, REPO, COMMIT as KEY=VALUE lines.
# Usage: cat .gitrepo | parse-gitrepo
#        parse-gitrepo < .gitrepo

set -euo pipefail

usage() { printf 'Usage: %s < path/to/.gitrepo\n       cat path/to/.gitrepo | %s\n' "$(basename "$0")" "$(basename "$0")" >&2; exit 1; }
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

# Read content from stdin into a variable
GITREPO_CONTENT=$(cat)

# Extract a value from "key = value" lines (whitespace tolerant).
get_value() {
  local key="$1"
  awk -F'=' -v k="$key" '
    $0 ~ "^[[:space:]]*"k"[[:space:]]*=" {
      val=$2
      sub(/^[[:space:]]+/,"",val)
      sub(/[[:space:]]+$/,"",val)
      print val
    }
  ' <<< "$GITREPO_CONTENT" | tail -n1
}

REMOTE="$(get_value remote)"; [[ -n "$REMOTE" ]] || { echo "ERROR: 'remote' not found" >&2; exit 1; }
COMMIT="$(get_value commit)"; [[ -n "$COMMIT" ]] || { echo "ERROR: 'commit' not found" >&2; exit 1; }

# Normalize GitHub remote -> "github.com/<owner>/<repo>[.git]"
case "$REMOTE" in
  git@github.com:*)        NORM="github.com/${REMOTE#git@github.com:}" ;;
  https://github.com/*)     NORM="${REMOTE#https://}" ;;
  ssh://git@github.com/*)   NORM="${REMOTE#ssh://}" ;;
  *) echo "ERROR: unsupported or non-GitHub remote: $REMOTE" >&2; exit 1 ;;
esac

# Parse owner/repo (strip optional .git)
if [[ "$NORM" =~ ^github\.com[:/]+([^/]+)/([^/]+)$ ]]; then
  OWNER="${BASH_REMATCH[1]}"
  REPO="${BASH_REMATCH[2]}"
  REPO="${REPO%.git}"
else
  echo "ERROR: could not parse owner/repo from remote: $REMOTE" >&2
  exit 1
fi

# Output as KEY=VALUE pairs (safe to eval/source)
printf 'OWNER=%s\n' "$OWNER"
printf 'REPO=%s\n' "$REPO"
printf 'COMMIT=%s\n' "$COMMIT"
