#!/usr/bin/env bash
# init-release-subrepo.sh — core of initialize.yml. Connects main's ./release
# folder to the repo's own `release` branch via git-subrepo, then publishes main.
# (README population and self-deletion of the init workflow stay in the action.)
#
# Inputs (env):
#   ORIGIN_URL     default: `git remote get-url origin` (the repo itself)
#   REMOTE         default: origin
#   MAIN_BRANCH    default: main
#   RELEASE_BRANCH default: release
#   RELEASE_DIR    default: release
set -euo pipefail
REMOTE="${REMOTE:-origin}"
MAIN_BRANCH="${MAIN_BRANCH:-main}"
RELEASE_BRANCH="${RELEASE_BRANCH:-release}"
RELEASE_DIR="${RELEASE_DIR:-release}"
ORIGIN_URL="${ORIGIN_URL:-$(git remote get-url "$REMOTE" 2>/dev/null || true)}"

[ -n "$ORIGIN_URL" ] || { echo "::error::could not determine origin URL"; exit 1; }
git ls-remote --heads "$ORIGIN_URL" "$RELEASE_BRANCH" | grep -q "refs/heads/${RELEASE_BRANCH}\$" \
  || { echo "::error::'$RELEASE_BRANCH' branch not found on $ORIGIN_URL (create the repo with all branches)"; exit 1; }
if [ -d "$RELEASE_DIR" ] && [ -n "$(ls -A "$RELEASE_DIR" 2>/dev/null)" ]; then
  echo "::error::./$RELEASE_DIR already exists and is non-empty"; exit 1
fi

git subrepo clone --branch="$RELEASE_BRANCH" "$ORIGIN_URL" "$RELEASE_DIR"
git push -u "$REMOTE" "$MAIN_BRANCH"
