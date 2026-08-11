#!/usr/bin/env bash
# init-main-core.sh — part of initialize.yml, runs *before*
# init-release-subrepo.sh. Clones the suede `core` dependency (main flavor)
# into .suede/core on the repo's `main` branch and pushes it.
#
# Must be run while `main` is checked out (the action handles the checkout;
# this script is intentionally single-branch). The clone happens here — rather
# than baking core into the template — so that .suede/core/.gitrepo points at a
# real commit of the actual core branch.
#
# A devcontainer is *not* installed here. A dependency's development
# environment is its own choice, so nothing about it is part of initialization;
# install devcontainers-suede by hand in the repositories that want one.
#
# Inputs (env):
#   REMOTE       default: origin
#   CORE_URL     default: https://github.com/pmalacho-mit/suede.git
#   CORE_BRANCH  default: dependency/main/core
#   CORE_DIR     default: .suede/core
set -euo pipefail
REMOTE="${REMOTE:-origin}"
CORE_URL="${CORE_URL:-https://github.com/pmalacho-mit/suede.git}"
CORE_BRANCH="${CORE_BRANCH:-dependency/main/core}"
CORE_DIR="${CORE_DIR:-.suede/core}"

if [ -d "$CORE_DIR" ] && [ -n "$(ls -A "$CORE_DIR" 2>/dev/null)" ]; then
  echo "::error::./$CORE_DIR already exists and is non-empty"; exit 1
fi

# Clone the core dependency (main flavor); git-subrepo commits this itself.
git subrepo clone --branch="$CORE_BRANCH" "$CORE_URL" "$CORE_DIR"
git push "$REMOTE" HEAD
