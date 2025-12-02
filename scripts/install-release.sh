#!/usr/bin/env bash
#
# Script to fetch a release/.gitrepo file from a remote repository, parse it
# to extract the referenced repository information (OWNER/REPO/COMMIT), and
# download the repository archive at that commit into a local destination.
#
# This script uses remote hosted utilities (git-raw.sh, extract-subrepo-config.sh,
# and degit.sh) to accomplish its task without requiring a full git clone.

set -euo pipefail

# ----- External Script Dependencies -----
# These scripts are downloaded and executed at runtime.
readonly EXTERNAL_SCRIPT_BASE="https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts"
readonly EXTERNAL_SCRIPT_GIT_RAW="${EXTERNAL_SCRIPT_BASE}/utils/git-raw.sh"
readonly EXTERNAL_SCRIPT_DEGIT="${EXTERNAL_SCRIPT_BASE}/utils/degit.sh"
readonly EXTERNAL_SCRIPT_EXTRACT="${EXTERNAL_SCRIPT_BASE}/extract-subrepo-config.sh"

# Print usage information to stderr.
usage() {
  cat >&2 <<'USAGE'
Usage: install-release.sh [OPTIONS] --repo OWNER/REPO

Fetch and extract the repository specified in a remote repository's release/.gitrepo file.

Options:
  -r, --repo OWNER/REPO (required) source repository containing release/.gitrepo
  -b, --branch BRANCH   branch to fetch release/.gitrepo from (default: main)
  -d, --destination DIR destination directory to extract into (default: repo name)
  -h, --help            display this help and exit

Notes:
  • The script fetches the release/.gitrepo file from the specified repository
    and branch, parses it to determine the actual release repository and commit,
    then downloads that release into the destination directory.
  • If --destination is not provided, the destination will be derived from the release
    repository name (the REPO value from release/.gitrepo, not the source repo).
  • The destination directory must be empty or nonexistent.

Examples:
  install-release.sh -r pmalacho-mit/zoom-sdk-suede
  install-release.sh -r pmalacho-mit/zoom-sdk-suede -b main --destination ./sdk-release
  install-release.sh -r owner/repo -b develop --destination ./my-release
USAGE
}

# Determine whether a directory contains any entries.  Returns 0 if
# populated, 1 if empty or nonexistent.
is_dir_populated() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  shopt -s nullglob dotglob
  local files=("$dir"/*)
  shopt -u nullglob dotglob
  (( ${#files[@]} > 0 ))
}

# ----- Main script begins -----

# Initialize variables for argument parsing.
REPO=""
BRANCH="main"
DEST=""
DEST_PROVIDED=false

# Process command line arguments.
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--repo)
      REPO="${2-}"
      if [[ -z "$REPO" ]]; then
        printf "Error: missing argument to %s\n" "$1" >&2
        usage
        exit 1
      fi
      shift 2
      ;;
    -b|--branch)
      BRANCH="${2-}"
      if [[ -z "$BRANCH" ]]; then
        printf "Error: missing argument to %s\n" "$1" >&2
        usage
        exit 1
      fi
      shift 2
      ;;
    -d|--destination)
      DEST="${2-}"
      DEST_PROVIDED=true
      if [[ -z "$DEST" ]]; then
        printf "Error: missing argument to %s\n" "$1" >&2
        usage
        exit 1
      fi
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      printf "Unknown option: %s\n" "$1" >&2
      usage
      exit 1
      ;;
    *)
      printf "Error: unexpected positional argument: %s\n" "$1" >&2
      usage
      exit 1
      ;;
  esac
done

# Validate required arguments.
if [[ -z "$REPO" ]]; then
  printf "Error: --repo OWNER/REPO is required\n" >&2
  usage
  exit 1
fi

if [[ "$REPO" != */* ]]; then
  printf "Error: --repo must be OWNER/REPO (got %s)\n" "$REPO" >&2
  exit 1
fi

printf "Fetching release/.gitrepo from %s (branch: %s)...\n" "$REPO" "$BRANCH" >&2

# Fetch the release/.gitrepo file from the remote repository.
GITREPO_CONTENT=$(bash <(curl -fsSL "$EXTERNAL_SCRIPT_GIT_RAW") \
  --repo "$REPO" \
  --branch "$BRANCH" \
  --file "release/.gitrepo") || {
    printf "Error: failed to fetch release/.gitrepo from %s (branch: %s)\n" "$REPO" "$BRANCH" >&2
    exit 1
  }

# Parse the .gitrepo content to extract OWNER, REPO, and COMMIT.
eval "$(echo "$GITREPO_CONTENT" | bash <(curl -fsSL "$EXTERNAL_SCRIPT_EXTRACT"))" || {
  printf "Error: failed to parse release/.gitrepo content\n" >&2
  exit 1
}

printf "Determined release ref: %s/%s@%s\n" "$OWNER" "$REPO" "$COMMIT" >&2

# Determine destination if not provided.
if [[ -z "$DEST" ]]; then
  DEST="$REPO"
  printf "Auto-derived destination: %s\n" "$DEST" >&2
fi

# Canonicalise DEST to remove any trailing slashes.
DEST="${DEST%/}"

# Check whether destination exists and is non-empty.
if is_dir_populated "$DEST"; then
  printf "Error: destination '%s' already exists and is not empty.\n" "$DEST" >&2
  exit 1
fi

# Ensure destination directory exists and is empty now.
mkdir -p "$DEST"

# Download and extract repository archive.
printf "Downloading %s/%s@%s into %s...\n" "$OWNER" "$REPO" "$COMMIT" "$DEST" >&2
bash <(curl -fsSL "$EXTERNAL_SCRIPT_DEGIT") \
  --repo     "${OWNER}/${REPO}" \
  --commit   "${COMMIT}" \
  --destination "${DEST}" || {
    printf "Error: failed to download and extract release\n" >&2
    exit 1
  }

# Save the .gitrepo content into the destination as `.gitrepo`.
echo "$GITREPO_CONTENT" > "$DEST/.gitrepo"

printf "✓ Successfully extracted %s/%s@%s into %s\n" "$OWNER" "$REPO" "$COMMIT" "$DEST" >&2
printf "Add and commit the changes to your repository, for example:\n" >&2
printf "  git add %s\n  git commit -m 'Add release %s/%s@%s'\n" "$DEST" "$OWNER" "$REPO" "$COMMIT" >&2