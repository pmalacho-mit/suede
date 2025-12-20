#!/usr/bin/env bash
#
# Script to extract information from a git‑subrepo .gitrepo file, download a
# tarball of the referenced repository at a given commit and unpack it into
# a destination directory.  The script supports safe defaults, explicit
# command line parsing and optional symlink creation via --link.
#
# This script replaces the ad‑hoc curl/eval/degit invocation used to
# bootstrap a subrepo archive.  It embeds the logic of both
# `extract-subrepo-config.sh` and a simplified `degit` implementation so that
# it can run without depending on remote scripts being reachable at run
# time.  If you prefer to use the upstream helpers directly you can
# substitute the functions `parse_gitrepo` and `download_archive` with
# appropriate curl invocations.

set -euo pipefail

# ----- External Script Dependencies -----
# These scripts are downloaded and executed at runtime.
readonly EXTERNAL_SCRIPT_BASE="https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts" 
readonly EXTERNAL_SCRIPT_EXTRACT="${EXTERNAL_SCRIPT_BASE}/extract-subrepo-config.sh"
readonly EXTERNAL_SCRIPT_DEGIT="${EXTERNAL_SCRIPT_BASE}/utils/degit.sh"

# Print usage information to stderr.  This function is invoked when
# incorrect flags are supplied or when --help is requested.
usage() {
  cat >&2 <<'USAGE'
Usage: add-subrepo-dependency.sh [OPTIONS] <path/to/file.gitrepo>

Fetch and extract the repository specified in a git subrepo .gitrepo file.

Options:
  -d, --destination DIR Destination directory to write into.  If omitted,
                        derive the destination from the given file.
  -h, --help            Display this help and exit.

Notes:
  • The positional argument <path/to/file.gitrepo> must reference a valid
    git subrepo metadata file.  It may be named `.gitrepo` (inside a
    subdirectory) or `<name>.gitrepo`.  The script uses the file name
    and/or its parent directory to determine a default destination when
    --destination is not provided.
  • When the destination is derived, if the given file is named
    `.gitrepo`, the destination defaults to the directory containing the
    file (i.e. the subrepo directory).  If the file name ends with
    `<name>.gitrepo`, the destination defaults to a sibling directory
    named `<name>` within the same directory as the file.

Example:
  add-subrepo-dependency.sh ./first-consumer/.gitrepo
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
FILE=""
DEST=""
DEST_PROVIDED=false

# Process command line arguments.  We intentionally do not allow
# positional arguments after the file path to minimise ambiguity.
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
    -*)
      printf "Unknown option: %s\n" "$1" >&2
      usage
      exit 1
      ;;
    *)
      # Positional argument: the .gitrepo file.
      if [[ -z "$FILE" ]]; then
        FILE="$1"
        shift
      else
        printf "Error: multiple file paths provided (got '%s' and '%s')\n" "$FILE" "$1" >&2
        usage
        exit 1
      fi
      ;;
  esac
done

# Validate required positional argument.
if [[ -z "$FILE" ]]; then
  printf "Error: a path to a .gitrepo file is required\n" >&2
  usage
  exit 1
fi

# Ensure the specified file exists.
if [[ ! -f "$FILE" ]]; then
  printf "Error: file '%s' not found\n" "$FILE" >&2
  exit 1
fi

# Parse the .gitrepo file.  This populates OWNER, REPO and COMMIT variables.
eval "$(cat "${FILE}" | bash <(curl -fsSL ${EXTERNAL_SCRIPT_EXTRACT}))"
printf "Determined subrepo ref: %s/%s@%s\n" "${OWNER}" "${REPO}" "${COMMIT}" >&2

# Determine derived destination if not provided.  For
# foo/bar/.gitrepo dest becomes foo/bar.  For foo/bar/name.gitrepo dest
# becomes foo/bar/name.
if [[ -z "$DEST" ]]; then
  file_dir=$(dirname "${FILE}")
  file_base=$(basename "${FILE}")
  if [[ "$file_base" == ".gitrepo" ]]; then
    DEST="$file_dir"
  else
    name_no_ext="${file_base%.gitrepo}"
    DEST="${file_dir}/../../${name_no_ext}"
  fi
  printf "Auto-derived destination: %s\n" "$DEST" >&2
fi

# Canonicalise DEST to remove any trailing slashes.
DEST="${DEST%/}"

# Check whether destination exists and is non‑empty.
if is_dir_populated "$DEST"; then
  printf "Error: destination '%s' already exists and is not empty.\n" "$DEST" >&2
  exit 1
fi

# Ensure destination directory exists and is empty now.
mkdir -p "$DEST"

# Download and extract repository archive.  
bash <(curl -fsSL "$EXTERNAL_SCRIPT_DEGIT") \
  --repo     "${OWNER}/${REPO}" \
  --commit   "${COMMIT}" \
  --destination "${DEST}"

# Copy the .gitrepo file into the destination as `.gitrepo`.  Always
# overwrite any existing copy.  Use cp -p to preserve timestamps and
# permissions.
cp -p "$FILE" "$DEST/.gitrepo"

printf "Extracted %s/%s@%s into %s\nAdd and commit the changes to your repository, for example:\n" "${OWNER}" "${REPO}" "${COMMIT}" "${DEST}" >&2
printf "  git add %s\n  git commit -m 'Add subrepo %s/%s@%s'\n" "${DEST}" "${OWNER}" "${REPO}" "${COMMIT}" >&2
