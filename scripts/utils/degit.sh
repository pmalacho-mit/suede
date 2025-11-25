set -euo pipefail

usage() {
  local cmd
  cmd="$(basename "$0")"
  cat >&2 <<USAGE
Usage:
  $cmd --repo OWNER/REPO [--branch BRANCH] [--commit SHA] [--directory DIR] [--include PATH...]
Options:
  -r, --repo OWNER/REPO     (required) repository in OWNER/REPO form
  -b, --branch BRANCH       branch or tag to fetch if --commit not supplied
  -c, --commit SHA          specific commit SHA to fetch (takes precedence)
  -d, --directory DIR       destination directory (default: repo name)
  -i, --include PATH...     only extract files matching these path patterns
  -h, --help                show this help

Examples:
  $cmd -r vercel/next.js
  $cmd -r sveltejs/svelte -b v5.0.0 -d svelte-src
  $cmd -r torvalds/linux -c 5c3f1b2 -d ./linux-snapshot
  $cmd -r facebook/react -i packages/react packages/shared
USAGE
  exit 1
}

# ---- Parse args ----
REPO=""
BRANCH=""
COMMIT=""
DEST=""
INCLUDE_PATHS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--repo)      REPO="${2-}"; shift 2 || usage ;;
    -b|--branch)    BRANCH="${2-}"; shift 2 || usage ;;
    -c|--commit)    COMMIT="${2-}"; shift 2 || usage ;;
    -d|--directory) DEST="${2-}"; shift 2 || usage ;;
    -i|--include)   
      shift
      while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
        INCLUDE_PATHS+=("$1")
        shift
      done
      ;;
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

# Infer dest from repo name if not provided.
if [[ -z "${DEST:-}" ]]; then
  DEST="${REPO##*/}"
fi

# ---- Dependencies ----
command -v curl >/dev/null 2>&1 || { echo "Error: curl not found" >&2; exit 3; }
command -v tar  >/dev/null 2>&1 || { echo "Error: tar not found"  >&2; exit 3; }

# ---- Headers (rate-limit friendly) ----
AUTH_HEADER=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  AUTH_HEADER+=( -H "Authorization: Bearer ${GITHUB_TOKEN}" )
elif [[ -n "${GH_TOKEN:-}" ]]; then
  AUTH_HEADER+=( -H "Authorization: Bearer ${GH_TOKEN}" )
fi
UA_HEADER=( -H "User-Agent: ghdegit-bash" )
ACCEPT_HEADER=( -H "Accept: application/vnd.github+json" )

# ---- Helpers for lightweight existence checks ----
api_get() {
  # $1: path like /repos/OWNER/REPO/branches/main
  curl -fsSL --connect-timeout 10 \
    "${UA_HEADER[@]}" "${ACCEPT_HEADER[@]}" ${AUTH_HEADER[@]+"${AUTH_HEADER[@]}"} \
    "https://api.github.com$1"
}

assert_branch_exists() {
  local owner repo branch
  owner="${REPO%%/*}"
  repo="${REPO##*/}"
  api_get "/repos/${owner}/${repo}/branches/${1}" >/dev/null || {
    echo "Error: branch '${1}' not found in ${REPO}." >&2
    exit 5
  }
}

assert_commit_exists() {
  local owner repo sha
  owner="${REPO%%/*}"
  repo="${REPO##*/}"
  api_get "/repos/${owner}/${repo}/commits/${1}" >/dev/null || {
    echo "Error: commit '${1}' not found in ${REPO}." >&2
    exit 6
  }
}

# If both provided, we validate both independently.
# (Tarball URL will be pinned to commit; branch is informational/sanity check.)
if [[ -n "$BRANCH" ]]; then
  assert_branch_exists "$BRANCH"
fi
if [[ -n "$COMMIT" ]]; then
  assert_commit_exists "$COMMIT"
fi

# ---- URL construction ----
BASE_URL="https://api.github.com/repos/${REPO}/tarball"
REF=""
if   [[ -n "$COMMIT" ]]; then REF="$COMMIT"
elif [[ -n "$BRANCH" ]]; then REF="$BRANCH"
else                           REF=""      # default branch tip
fi

URL="$BASE_URL"
[[ -n "$REF" ]] && URL="${BASE_URL}/${REF}"

# ---- Destination checks ----
mkdir -p "$DEST"
if [ -n "$(ls -A "$DEST" 2>/dev/null)" ]; then
  echo "Error: destination '$DEST' is not empty. Choose an empty dir or remove it." >&2
  exit 4
fi

echo "Fetching from $URL ..."

# ---- Fetch & extract ----
# Build tar arguments
TAR_ARGS=(-xz --strip-components=1 -C "$DEST")

# If include paths specified, add wildcards for filtering
if [[ ${#INCLUDE_PATHS[@]} -gt 0 ]]; then
  TAR_ARGS+=(--wildcards --no-wildcards-match-slash)
  for path in "${INCLUDE_PATHS[@]}"; do
    # Add pattern matching any top-level dir (GitHub tarball prefix) + user path
    # Use a single pattern that matches the directory and all its contents recursively
    TAR_ARGS+=("*/${path}*")
  done
fi

curl -fLSS --retry 3 --connect-timeout 10 \
  "${UA_HEADER[@]}" "${ACCEPT_HEADER[@]}" ${AUTH_HEADER[@]+"${AUTH_HEADER[@]}"} \
  "$URL" \
| tar "${TAR_ARGS[@]}"

# ---- Done ----
if [[ -n "$COMMIT" && -n "$BRANCH" ]]; then
  printf "✓ Fetched %s (commit %s on branch %s) into %s\n" "$REPO" "$COMMIT" "$BRANCH" "$DEST"
elif [[ -n "$COMMIT" ]]; then
  printf "✓ Fetched %s (commit %s) into %s\n" "$REPO" "$COMMIT" "$DEST"
elif [[ -n "$BRANCH" ]]; then
  printf "✓ Fetched %s (ref %s) into %s\n" "$REPO" "$BRANCH" "$DEST"
else
  printf "✓ Fetched %s (default branch tip) into %s\n" "$REPO" "$DEST"
fi
