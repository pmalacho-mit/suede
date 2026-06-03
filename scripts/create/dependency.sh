#!/usr/bin/env bash
set -euo pipefail

# Create a repo from the suede-dependency-template, apply the settings the
# README asks for, dispatch the initialization workflow, and follow it to
# completion — all in one shot.
#
# Usage:
#   ./create-suede-repo.sh <name> [public|private] [--cleanup]
#   ./create-suede-repo.sh my-dep                 # public, kept
#   ./create-suede-repo.sh my-dep private          # private, kept
#   ./create-suede-repo.sh temp --cleanup          # throwaway test, deleted on success
#
# <name> is required. With --cleanup the repo is deleted only if init
# succeeds; on failure it's left intact so you can inspect what went wrong.

# ── Config ──────────────────────────────────────────────────────────────
TEMPLATE="pmalacho-mit/suede-dependency-template"
WORKFLOW="initialize.yml"        # the init workflow that self-destructs
# ────────────────────────────────────────────────────────────────────────

# Parse args: --cleanup can appear anywhere; the rest are positional.
CLEANUP=false
POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --cleanup) CLEANUP=true; shift ;;
    -h|--help) sed -n '4,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"

if [ "$#" -lt 1 ] || [ -z "${1:-}" ]; then
  echo "Error: repo name is required." >&2
  echo "Usage: $(basename "$0") <name> [public|private] [--cleanup]" >&2
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

OWNER="$(gh api user --jq .login)"
REPO="$OWNER/$NAME"

echo "▶ Creating $REPO from $TEMPLATE …"
gh repo create "$REPO" --template "$TEMPLATE" --"$VISIBILITY"

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

echo "✅ Init succeeded.  Result:  https://github.com/$REPO"

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