#!/usr/bin/env bash
set -euo pipefail

# Generates installation instructions for the root README.md using suede.sh.
#
# Parses the git remote origin URL to extract host and path components,
# which are required for the suede.sh installation script.
#
# Safe to run on GitHub runners and locally. Existing README.md content is preserved.

ROOT="$PWD"
README="$ROOT/README.md"

log() { printf '[generate-install-md] %s\n' "$*"; }

# Detect repo name (folder name of the top-level git dir)
REPO_NAME="$(basename "$(git rev-parse --show-toplevel)")"
# Humanize: replace -/_ with spaces, then Title Case
REPO_NAME_READABLE="$(
  printf '%s\n' "$REPO_NAME" \
  | tr '[-_]' ' ' \
  | awk '{ for (i=1;i<=NF;i++) { $i=toupper(substr($i,1,1)) substr($i,2) } print }'
)"
log "Detected repo name: $REPO_NAME (readable: $REPO_NAME_READABLE)"

# Fetch the origin URL
if git remote get-url origin >/dev/null 2>&1; then
  ORIGIN_URL="$(git remote get-url origin)"
else
  log "ERROR: Could not determine repo URL from git remote 'origin'"
  exit 1
fi
log "Origin URL: $ORIGIN_URL"

# Parse remote into host and path
_host=""; _path=""
case "$ORIGIN_URL" in
  http://*|https://*)
    _rest="${ORIGIN_URL#*://}"
    _host="${_rest%%/*}"
    _path="${_rest#*/}"
    ;;
  ssh://*)
    _rest="${ORIGIN_URL#ssh://}"
    _rest="${_rest#*@}"
    _host="${_rest%%/*}"
    _path="${_rest#*/}"
    ;;
  *@*:*|*:* )
    _left="${ORIGIN_URL%%:*}"
    _host="${_left#*@}"
    _path="${ORIGIN_URL#*:}"
    ;;
  *)
    log "ERROR: Unrecognized remote format. Could not parse host and path from: $ORIGIN_URL"
    exit 1
    ;;
esac

# Ensure we successfully parsed host and path
if [[ -z "$_host" || -z "$_path" ]]; then
  log "ERROR: Failed to extract host and path from origin URL: $ORIGIN_URL"
  exit 1
fi

ensure_git_suffix() {
  case "$1" in
    *.git) printf '%s' "$1" ;;
    *)     printf '%s.git' "$1" ;;
  esac
}

_path="$(ensure_git_suffix "$_path")"
_repo_id="${_path%.git}"

log "Parsed host: $_host"
log "Parsed path: $_path"
log "Parsed repo identifier: $_repo_id"

RELEASE_URL="https://$_host/$_repo_id/tree/release"

# Build the new content
cat > "$README" <<EOF
# $REPO_NAME_READABLE

This repo is a [suede dependency](https://github.com/pmalacho-mit/suede). 

To see the installable source code, please checkout the [release branch]($RELEASE_URL).

## Installation

\`\`\`bash
bash <(curl https://suede.sh/install-release) --repo $_repo_id
\`\`\`

<details>
<summary>
See alternative to using <a href="https://github.com/pmalacho-mit/suede#suedesh">suede.sh</a> script proxy
</summary>

\`\`\`bash
bash <(curl https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts/install-release.sh) --repo $_repo_id
\`\`\`

</details>

EOF


