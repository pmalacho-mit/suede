#!/usr/bin/env bash
set -euo pipefail

usage() {
  local cmd
  cmd="$(basename "$0")"
  cat >&2 <<USAGE
Usage:
  $cmd --repo OWNER/REPO --file PATH [--branch BRANCH] [--commit SHA]
Options:
  -r, --repo OWNER/REPO     (required) repository in OWNER/REPO form
  -f, --file PATH           (required) path to file within the repository
  -b, --branch BRANCH       branch or tag to fetch if --commit not supplied
  -c, --commit SHA          specific commit SHA to fetch (takes precedence)
  -h, --help                show this help

Examples:
  $cmd -r facebook/react -f package.json
  $cmd -r vercel/next.js -f packages/next/package.json -b canary
  $cmd -r torvalds/linux -f README -c 5c3f1b2
USAGE
  exit 1
}

# ---- Parse args ----
REPO=""
FILE_PATH=""
BRANCH=""
COMMIT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--repo)      REPO="${2-}"; shift 2 || usage ;;
    -f|--file)      FILE_PATH="${2-}"; shift 2 || usage ;;
    -b|--branch)    BRANCH="${2-}"; shift 2 || usage ;;
    -c|--commit)    COMMIT="${2-}"; shift 2 || usage ;;
    -h|--help)      usage ;;
    --)             shift; break ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      ;;
    *)
      echo "Unexpected positional argument: $1" >&2
      usage
      ;;
  esac
done

# ---- Validation ----
if [[ -z "$REPO" ]]; then
  echo "Error: --repo OWNER/REPO is required." >&2
  usage
fi
if [[ "$REPO" != */* ]]; then
  printf "Error: --repo must be OWNER/REPO (got %s)\n" "$REPO" >&2
  exit 2
fi
if [[ -z "$FILE_PATH" ]]; then
  echo "Error: --file PATH is required." >&2
  usage
fi

# Remove leading slash from file path if present
FILE_PATH="${FILE_PATH#/}"

# ---- Dependencies ----
command -v curl >/dev/null 2>&1 || { echo "Error: curl not found" >&2; exit 3; }

# ---- Headers (rate-limit friendly) ----
AUTH_HEADER=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  AUTH_HEADER+=( -H "Authorization: Bearer ${GITHUB_TOKEN}" )
elif [[ -n "${GH_TOKEN:-}" ]]; then
  AUTH_HEADER+=( -H "Authorization: Bearer ${GH_TOKEN}" )
fi
UA_HEADER=( -H "User-Agent: git-raw-bash" )

# ---- URL construction ----
# Use raw.githubusercontent.com for simple raw file access
BASE_URL="https://raw.githubusercontent.com/${REPO}"
REF=""
if   [[ -n "$COMMIT" ]]; then REF="$COMMIT"
elif [[ -n "$BRANCH" ]]; then REF="$BRANCH"
else                           REF="HEAD"  # default branch
fi

URL="${BASE_URL}/${REF}/${FILE_PATH}"

# ---- Fetch & output ----
curl -fLSs --retry 3 --connect-timeout 10 \
  "${UA_HEADER[@]}" ${AUTH_HEADER[@]+"${AUTH_HEADER[@]}"} \
  "$URL" || {
    echo "Error: failed to fetch file '${FILE_PATH}' from ${REPO} (ref: ${REF})" >&2
    exit 4
  }