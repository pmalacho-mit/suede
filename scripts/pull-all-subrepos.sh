#!/usr/bin/env bash
#
# Script to find and update all git-subrepo directories in the current repository.
# Automatically discovers all .gitrepo files and runs `git subrepo pull` on each.

set -e

# Color and formatting (only enable when stderr is a TTY)
if [[ -t 2 ]]; then
  BOLD=$'\033[1m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  RED=$'\033[31m'
  RESET=$'\033[0m'
else
  BOLD=''
  GREEN=''
  YELLOW=''
  RED=''
  RESET=''
fi

# Find all .gitrepo files and extract their parent directories
SUBREPO_DIRS=$(find . -name ".gitrepo" -type f | sed 's|/\.gitrepo$||' | sort -u)

if [ -z "$SUBREPO_DIRS" ]; then
  printf "%bNo subrepos found.%b\n" "$YELLOW" "$RESET" >&2
  exit 0
fi

printf "%bFound subrepos:%b\n" "$BOLD" "$RESET" >&2
printf "%s\n" "$SUBREPO_DIRS" >&2
printf "\n" >&2

# Pull each subrepo
for dir in $SUBREPO_DIRS; do
  printf "%b==================================================%b\n" "$BOLD" "$RESET" >&2
  printf "%bUpdating subrepo:%b %s\n" "$BOLD" "$RESET" "$dir" >&2
  printf "%b==================================================%b\n" "$BOLD" "$RESET" >&2

  if git subrepo pull "$dir"; then
    printf "%b✓ Successfully pulled %s%b\n" "$GREEN" "$dir" "$RESET" >&2
  else
    printf "%b⚠ Failed to pull %s (may be up to date or have conflicts)%b\n" "$YELLOW" "$dir" "$RESET" >&2
  fi
  printf "\n" >&2
done