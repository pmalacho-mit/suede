#!/usr/bin/env bash
# init-release-core.sh — part of initialize.yml, runs *before*
# init-release-subrepo.sh. Clones the suede `core` dependency (release flavor)
# into .suede/core on the repo's `release` branch and pushes it.
#
# Must be run while the `release` branch is checked out (the action handles the
# checkout; this script is intentionally single-branch). The clone happens on
# `release` — rather than baking core into the template — so that core's
# ./.suede/core/.gitrepo points at a real commit of the actual core branch.
#
# Inputs (env):
#   REMOTE       default: origin
#   CORE_URL     default: https://github.com/pmalacho-mit/suede.git
#   CORE_BRANCH  default: dependency/release/core
#   CORE_DIR     default: .suede/core
set -euo pipefail
REMOTE="${REMOTE:-origin}"
CORE_URL="${CORE_URL:-https://github.com/pmalacho-mit/suede.git}"
CORE_BRANCH="${CORE_BRANCH:-dependency/release/core}"
CORE_DIR="${CORE_DIR:-.suede/core}"

if [ -d "$CORE_DIR" ] && [ -n "$(ls -A "$CORE_DIR" 2>/dev/null)" ]; then
  echo "::error::./$CORE_DIR already exists and is non-empty"; exit 1
fi

git subrepo clone --branch="$CORE_BRANCH" "$CORE_URL" "$CORE_DIR"
git push "$REMOTE" HEAD
