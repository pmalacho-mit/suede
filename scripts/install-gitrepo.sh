#!/usr/bin/env bash
#
# Script to parse in the piped-in content of .gitrepo file,
# extract the referenced repository information (OWNER/REPO/COMMIT),
# and download the repository archive at that commit into a local destination.
#
# This script uses remote hosted utilities (extract-subrepo-config.sh and utils/degit.sh) 
# to accomplish its task without requiring a full git clone.

set -euo pipefail

# ----- External Script Dependencies -----
# These scripts are downloaded and executed at runtime.
readonly EXTERNAL_SCRIPT_BASE="https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts"
readonly EXTERNAL_SCRIPT_DEGIT="${EXTERNAL_SCRIPT_BASE}/utils/degit.sh"
readonly EXTERNAL_SCRIPT_EXTRACT_CONFIG="${EXTERNAL_SCRIPT_BASE}/extract-subrepo-config.sh"
readonly EXTERNAL_SCRIPT_EXTRACT_DEPS="${EXTERNAL_SCRIPT_BASE}/check-dependencies.sh"

readonly INVOKE_INSTALL_GITREPO="bash <(curl https://suede.sh/install-gitrepo)"

# Color and formatting (only enable when stderr is a TTY)
if [[ -t 2 ]]; then
  # Use actual escape sequences (bash $'...') so printf %b works correctly
  BOLD=$'\033[1m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  CYAN=$'\033[36m'
  RESET=$'\033[0m'
else
  BOLD=''
  GREEN=''
  YELLOW=''
  CYAN=''
  RESET=''
fi

# Print usage information to stderr.
usage() {
  cat >&2 <<USAGE
Usage: $INVOKE_INSTALL_GITREPO -d <destination> [<path>|-]

Reads the content of a .gitrepo file and installs the referenced repository
archive at the specified commit into <destination>.

Options:
  -d, --destination <path>   Destination directory (required)
  -h, --help                 Show this help and exit

Positional arguments:
  <path>   Path to a local .gitrepo file. Use '-' to read the content from STDIN.

Examples:
  # Read from a local file by piping it in:
  cat release/.gitrepo | $INVOKE_INSTALL_GITREPO -d vendor/release -

  # Or pass the filename directly:
  $INVOKE_INSTALL_GITREPO -d vendor/release release/.gitrepo

  # Read content from a remote URL:
  curl -fsSL https://example.com/release/.gitrepo | $INVOKE_INSTALL_GITREPO -d vendor/release -
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

DEST=""
DEST_PROVIDED=false
CONTENT_SOURCE=""

# Process command line arguments.
while [[ $# -gt 0 ]]; do
  case "$1" in
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
    -)
      # '-' is commonly used to indicate reading from STDIN; treat it as a positional argument.
      CONTENT_SOURCE="-"
      shift
      ;;
    -*)
      printf "Unknown option: %s\n" "$1" >&2
      usage
      exit 1
      ;;
    *)
      if [[ -z "${CONTENT_SOURCE-}" ]]; then
        CONTENT_SOURCE="$1"
        shift
      else
        printf "Error: unexpected positional argument: %s\n" "$1" >&2
        usage
        exit 1
      fi
      ;;
  esac
done

# Ensure destination was provided.
if [[ "${DEST_PROVIDED-}" != true ]]; then
  printf "Error: destination is required (--destination/-d)\n" >&2
  usage
  exit 1
fi

# Read .gitrepo content from the positional argument, or from stdin if '-' or if content is piped.
if [[ -n "${CONTENT_SOURCE-}" ]]; then
  if [[ "$CONTENT_SOURCE" == "-" ]]; then
    GITREPO_CONTENT="$(cat -)"
  elif [[ -f "$CONTENT_SOURCE" ]]; then
    GITREPO_CONTENT="$(< "$CONTENT_SOURCE")"
  else
    printf "Error: '%s' is not a readable file\n" "$CONTENT_SOURCE" >&2
    exit 1
  fi
else
  # No positional arg given; attempt to read from stdin if available.
  if [ -t 0 ]; then
    printf "Error: no .gitrepo content provided; pass a file path or pipe content via '-' or stdin\n" >&2
    usage
    exit 1
  fi
  GITREPO_CONTENT="$(cat -)"
fi

# Ensure we have non-empty content.
if [[ -z "${GITREPO_CONTENT//[[:space:]]/}" ]]; then
  printf "Error: .gitrepo content is empty\n" >&2
  exit 1
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

# Parse the .gitrepo content to extract OWNER, REPO, and COMMIT.
eval "$(echo "$GITREPO_CONTENT" | bash <(curl -fsSL "$EXTERNAL_SCRIPT_EXTRACT_CONFIG"))" || {
  printf "Error: failed to parse .gitrepo content\n" >&2
  exit 1
}

# Download and extract repository archive.
printf "Downloading %s/%s@%s into %s...\n" "$OWNER" "$REPO" "$COMMIT" "$DEST" >&2
bash <(curl -fsSL "$EXTERNAL_SCRIPT_DEGIT") \
  --repo     "${OWNER}/${REPO}" \
  --commit   "${COMMIT}" \
  --destination "${DEST}" || {
    printf "Error: failed to download and extract release\n" >&2
    exit 1
  }

# Get the current commit SHA of the parent repository.
PARENT_COMMIT=$(git rev-parse HEAD 2>/dev/null) || {
  printf "Warning: could not determine current commit SHA (not in a git repository?)\n" >&2
  PARENT_COMMIT=""
}

# Update the parent line in the .gitrepo content if we have a parent commit.
if [[ -n "$PARENT_COMMIT" ]]; then
  GITREPO_CONTENT=$(echo "$GITREPO_CONTENT" | sed "s/^\(\s*parent\s*=\s*\).*/\1$PARENT_COMMIT/")
fi

# Save the .gitrepo content into the destination as `.gitrepo`.
echo "$GITREPO_CONTENT" > "$DEST/.gitrepo"

printf "%s✓ Successfully extracted %s/%s@%s into %s%s\n" "$BOLD$GREEN" "$OWNER" "$REPO" "$COMMIT" "$DEST" "$RESET" >&2

if ! mapfile -t add_targets < <(bash <(curl -fsSL "$EXTERNAL_SCRIPT_EXTRACT_DEPS") "$DEST" --message "NEXT STEPS" --emit-add-targets); then
  printf "Error: failed to generate NEXT STEPS\n" >&2
  exit 1
fi

# Ensure at least DEST is present
if (( ${#add_targets[@]} == 0 )); then
  add_targets=("$DEST")
fi

printf "  %sCommit the changes to your repository:%s\n" "$BOLD" "$RESET" >&2
# Print the git add line with all targets (joined by spaces)
printf "    %s%s%s\n" "$GREEN" "git add ${add_targets[*]}" "$RESET" >&2

# Construct a commit message similar to the original if owner/repo/commit were provided
if [[ -n "$OWNER" ]] && [[ -n "$REPO" ]] && [[ -n "$COMMIT" ]]; then
  commit_msg="Add suede dependency (release) $OWNER/$REPO@$COMMIT"
else
  commit_msg="Add suede dependency (release)"
fi

printf "    %s%s%s\n\n" "$GREEN" "git commit -m '$commit_msg'" "$RESET" >&2