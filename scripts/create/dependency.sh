#!/usr/bin/env bash
set -euo pipefail

# Create a repo from the suede-dependency-template, apply the settings the
# README asks for, dispatch the initialization workflow, and follow it to
# completion — all in one shot.
#
# Usage:
#   ./create-suede-repo.sh <name> [public|private] [--org <org>] [--cleanup]
#   ./create-suede-repo.sh my-dep                  # public, under your account
#   ./create-suede-repo.sh my-dep private          # private, under your account
#   ./create-suede-repo.sh my-dep --org my-org     # public, under an organization
#   ./create-suede-repo.sh temp --cleanup          # throwaway test, deleted on success
#
# <name> is required. With --org <org> the repo is created in that organization
# (you must be a member with permission to create repos there) instead of your
# personal account. With --cleanup the repo is deleted only if init succeeds;
# on failure it's left intact so you can inspect what went wrong.

# ── Config ──────────────────────────────────────────────────────────────
TEMPLATE="pmalacho-mit/suede-dependency-template"
WORKFLOW="initialize.yml"        # the init workflow that self-destructs
# ────────────────────────────────────────────────────────────────────────

# Print a clickable terminal hyperlink (OSC 8). Falls back to a bare URL when
# stdout isn't a TTY (e.g. piped to a file or CI logs), so nothing is mangled.
#   hyperlink <url> [label]
hyperlink() {
  local url="$1" label="${2:-$1}"
  if [ -t 1 ]; then
    printf '\e]8;;%s\e\\%s\e]8;;\e\\\n' "$url" "$label"
  else
    printf '%s\n' "$url"
  fi
}

# Parse args: --cleanup/--org can appear anywhere; the rest are positional.
CLEANUP=false
ORG=""
POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --cleanup) CLEANUP=true; shift ;;
    --org)
      if [ -z "${2:-}" ]; then echo "Error: --org requires an organization name." >&2; exit 2; fi
      ORG="$2"; shift 2 ;;
    --org=*) ORG="${1#--org=}"; shift ;;
    -h|--help) sed -n '4,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"

if [ "$#" -lt 1 ] || [ -z "${1:-}" ]; then
  echo "Error: repo name is required." >&2
  echo "Usage: $(basename "$0") <name> [public|private] [--org <org>] [--cleanup]" >&2
  exit 2
fi

NAME="$1"
VISIBILITY="${2:-public}"        # public | private

# Preflight: gh must be installed and authenticated before we touch anything.
if ! command -v gh >/dev/null 2>&1; then
  echo "Error: GitHub CLI ('gh') is not installed." >&2
  echo "       Install it from https://cli.github.com/ and try again." >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "Error: not authenticated with GitHub. Run:" >&2
  echo "       gh auth login" >&2
  exit 1
fi

if [ -n "$ORG" ]; then
  # Verify membership early so we fail before creating anything. The public
  # members endpoint only sees public membership, so if that misses, fall back
  # to /memberships, which reports your own membership even when it's private.
  ME="$(gh api user --jq .login)"
  if ! gh api "/orgs/$ORG/members/$ME" >/dev/null 2>&1 \
     && ! gh api "/orgs/$ORG/memberships/$ME" --jq '.state == "active"' 2>/dev/null | grep -q true; then
    echo "Error: you don't appear to be a member of the '$ORG' organization" >&2
    echo "       (or it doesn't exist). Check the name and your access." >&2
    exit 1
  fi
  OWNER="$ORG"
else
  OWNER="$(gh api user --jq .login)"
fi
REPO="$OWNER/$NAME"

echo "▶ Creating $REPO from $TEMPLATE …"
gh repo create "$REPO" --template "$TEMPLATE" --"$VISIBILITY" --include-all-branches

echo "▶ Setting workflow permissions (read/write + allow PR create/approve) …"
gh api --method PUT "/repos/$REPO/actions/permissions/workflow" \
  -f default_workflow_permissions=write \
  -F can_approve_pull_request_reviews=true

echo "▶ Enabling auto-delete of head branches on merge …"
gh api --method PATCH "/repos/$REPO" -F delete_branch_on_merge=true

# Workflows aren't always dispatchable the instant the repo is generated.
echo "▶ Waiting for the workflow to register …"
for _ in $(seq 1 15); do
  if gh workflow view "$WORKFLOW" --repo "$REPO" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

echo "▶ Dispatching the initialization workflow …"
gh workflow run "$WORKFLOW" --repo "$REPO"

# Give the run a moment to be created, then grab its id and follow it.
sleep 4
RUN_ID="$(gh run list --workflow "$WORKFLOW" --repo "$REPO" \
            --limit 1 --json databaseId --jq '.[0].databaseId')"

echo "▶ Watching run $RUN_ID …"
gh run watch "$RUN_ID" --repo "$REPO" --exit-status

echo "✅ Init succeeded.  Result:"
printf '   '; hyperlink "https://github.com/$REPO"

if [ "$CLEANUP" = true ]; then
  echo "▶ Cleaning up (--cleanup) …"
  if gh repo delete "$REPO" --yes; then
    echo "🧹 Deleted $REPO"
  else
    cat >&2 <<EOF

⚠️  Couldn't delete $REPO.
   The most likely cause is that your gh token lacks the 'delete_repo' scope.
   Authorize it and then re-run the delete:

     gh auth refresh -h github.com -s delete_repo
     gh repo delete $REPO --yes
EOF
    exit 1
  fi
else
  echo "   Tear down with:           gh repo delete $REPO --yes"
fi