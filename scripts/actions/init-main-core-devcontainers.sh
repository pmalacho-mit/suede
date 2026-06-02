#!/usr/bin/env bash
# init-main-core-devcontainers.sh — part of initialize.yml, runs *before*
# init-release-subrepo.sh. On the repo's `main` branch:
#   1. Clones the suede `core` dependency (main flavor) into .suede/core.
#   2. Installs devcontainers-suede and links .devcontainer/devcontainer.json.
#   3. Commits and pushes the devcontainer config.
#
# Must be run while `main` is checked out (the action handles the checkout;
# this script is intentionally single-branch). core/devcontainers are cloned in
# here — rather than baked into the template — so their .gitrepo files point at
# real commits of the actual repositories.
#
# Inputs (env):
#   REMOTE                 default: origin
#   CORE_URL               default: https://github.com/pmalacho-mit/suede.git
#   CORE_BRANCH            default: dependency/main/core
#   CORE_DIR               default: .suede/core
#   DEVCONTAINERS_REPO     default: pmalacho-mit/devcontainers-suede
#   DEVCONTAINERS_DIR      default: .suede/devcontainers-suede
#   DEVCONTAINER_PROFILE   default: common.json
#   SUEDE_INSTALL_RELEASE  default: https://suede.sh/install/release
set -euo pipefail
REMOTE="${REMOTE:-origin}"
CORE_URL="${CORE_URL:-https://github.com/pmalacho-mit/suede.git}"
CORE_BRANCH="${CORE_BRANCH:-dependency/main/core}"
CORE_DIR="${CORE_DIR:-.suede/core}"
DEVCONTAINERS_REPO="${DEVCONTAINERS_REPO:-pmalacho-mit/devcontainers-suede}"
DEVCONTAINERS_DIR="${DEVCONTAINERS_DIR:-.suede/devcontainers-suede}"
DEVCONTAINER_PROFILE="${DEVCONTAINER_PROFILE:-common.json}"
SUEDE_INSTALL_RELEASE="${SUEDE_INSTALL_RELEASE:-https://suede.sh/install/release}"

if [ -d "$CORE_DIR" ] && [ -n "$(ls -A "$CORE_DIR" 2>/dev/null)" ]; then
  echo "::error::./$CORE_DIR already exists and is non-empty"; exit 1
fi

# Clone the core dependency (main flavor); git-subrepo commits this itself.
git subrepo clone --branch="$CORE_BRANCH" "$CORE_URL" "$CORE_DIR"

# Install devcontainers-suede and link the chosen profile as
# .devcontainer/devcontainer.json (install.sh derives the symlink + repo root).
bash <(curl -fsSL "$SUEDE_INSTALL_RELEASE") --repo "$DEVCONTAINERS_REPO" --destination "$DEVCONTAINERS_DIR" --no-suffix
bash "$DEVCONTAINERS_DIR/install.sh" "$DEVCONTAINER_PROFILE"

git add "$DEVCONTAINERS_DIR" .devcontainer/devcontainer.json
git commit -m "chore(suede-init): install devcontainers-suede + link devcontainer.json"
git push "$REMOTE" HEAD
