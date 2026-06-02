#!/usr/bin/env bash
#
# Script to fetch a release/.gitrepo file from a remote repository, parse it
# to extract the referenced repository information (OWNER/REPO/COMMIT), and
# download the repository archive at that commit into a local destination.
#
# This script uses remote hosted utilities (utils/git-raw.sh, extract/subrepo-config.sh,
# and utils/degit.sh) to accomplish its task without requiring a full git clone.

set -euo pipefail

# ----- External Script Dependencies -----
# These scripts are downloaded and executed at runtime.
readonly EXTERNAL_SCRIPT_BASE="https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts"
readonly EXTERNAL_SCRIPT_GIT_RAW="${EXTERNAL_SCRIPT_BASE}/utils/git-raw.sh"
readonly EXTERNAL_SCRIPT_INSTALL="${EXTERNAL_SCRIPT_BASE}/install/gitrepo.sh"

# Print usage information to stderr.
usage() {
  cat >&2 <<'USAGE'
Usage: bash <(curl https://suede.sh/install/release) [OPTIONS] --repo OWNER/REPO

Fetch and extract the repository specified in a remote repository's release/.gitrepo file.

Options:
  -r, --repo OWNER/REPO (required) source repository containing release/.gitrepo
  -b, --branch BRANCH   branch to fetch release/.gitrepo from (default: main)
  -d, --destination DIR destination directory to extract into (default: repo name).
                        Unless --no-suffix is given, the destination is suffixed
                        with the short SHA (first 7 chars) of the installed commit.
      --no-suffix       do not append the commit short SHA to the destination
                        (use the destination exactly as given/derived)
  -h, --help            display this help and exit

Notes:
  • The script fetches the release/.gitrepo file from the specified repository
    and branch, parses it to determine the actual release repository and commit,
    then downloads that release into the destination directory.
  • If --destination is not provided, the destination will be derived from the release
    repository name (the REPO value from release/.gitrepo, not the source repo).
  • The final destination is suffixed with "-<short-sha>", where <short-sha> is
    the first 7 characters of the commit referenced by release/.gitrepo (e.g.
    ./sdk-release becomes ./sdk-release-7aeab3b). This pins the install location
    to the installed commit. Pass --no-suffix to use the destination exactly as
    given/derived, with no commit suffix.
  • The destination directory must be empty or nonexistent.

Examples:
  # installs into ./zoom-sdk-suede-<short-sha>
  bash <(curl https://suede.sh/install/release) -r pmalacho-mit/zoom-sdk-suede
  # installs into ./sdk-release-<short-sha>
  bash <(curl https://suede.sh/install/release) -r pmalacho-mit/zoom-sdk-suede -b main --destination ./sdk-release
  # installs into ./my-release-<short-sha>
  bash <(curl https://suede.sh/install/release) -r owner/repo -b develop --destination ./my-release
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
NO_SUFFIX=false

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
      if [[ -z "$DEST" ]]; then
        printf "Error: missing argument to %s\n" "$1" >&2
        usage
        exit 1
      fi
      shift 2
      ;;
    --no-suffix)
      NO_SUFFIX=true
      shift
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

# Determine destination if not provided (use only the repo name part of OWNER/REPO).
if [[ -z "$DEST" ]]; then
  DEST="${REPO#*/}"
  printf "Auto-derived destination: %s\n" "$DEST" >&2
fi

# Extract the referenced commit from the fetched release/.gitrepo and suffix the
# destination with its short SHA (first 7 chars, matching git's short-hash
# convention) so the install location is pinned to the installed commit. This
# is skipped when --no-suffix is given, leaving the destination exactly as
# given/derived.
if [[ "$NO_SUFFIX" != true ]]; then
  COMMIT=$(printf '%s\n' "$GITREPO_CONTENT" | awk -F'=' '
    $0 ~ /^[[:space:]]*commit[[:space:]]*=/ {
      val = $2
      sub(/^[[:space:]]+/, "", val)
      sub(/[[:space:]]+$/, "", val)
      print val
    }' | tail -n1)

  if [[ -z "$COMMIT" ]]; then
    printf "Error: could not find a commit in the fetched release/.gitrepo\n" >&2
    exit 1
  fi

  DEST="${DEST%/}-${COMMIT:0:7}"
  printf "Commit-suffixed destination: %s\n" "$DEST" >&2
fi

# Delegate installation to the hosted `install-gitrepo` script by piping the
# fetched release/.gitrepo content into it.  This centralizes parsing,
# extraction and any extra dependency handling in a single place.
if ! echo "$GITREPO_CONTENT" | bash <(curl -fsSL "$EXTERNAL_SCRIPT_INSTALL") -d "$DEST" -; then
  printf "Error: install-gitrepo failed to install the release into %s\n" "$DEST" >&2
  exit 1
fi

# `install-gitrepo` prints success and next steps; mirror its success exit.
exit 0