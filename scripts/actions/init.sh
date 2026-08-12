#!/usr/bin/env bash
# init.sh — everything `initialize.yml` does to the repository, in one script,
# run once with `main` checked out.
#
#   1. .suede/core            <- dependency/main/core     (the maintainer's tools)
#   2. ./release              <- this repo's own `release` branch
#   3. ./release/.suede/core  <- dependency/release/core   (what ships to consumers)
#   4. publish ./release to the `release` branch, and push `main`
#
# Step 3 is the whole point of the ordering. The consumer-facing core is
# vendored *inside* the release folder, so it reaches the `release` branch the
# way every other piece of release content does: through `main`. Nothing here
# checks `release` out, and nothing ever needs to again - `git subrepo pull
# release/.suede/core` on `main` is how that core is updated from then on.
#
# Step 4 is done here rather than left to `subrepo-push-release`, because a
# push made with the default GITHUB_TOKEN does not trigger another workflow.
# If something does trigger it later, it will find nothing to do.
#
# The cores are cloned at init time rather than baked into the template so
# their `.gitrepo` files point at real commits of the real core branches.
#
# A devcontainer is *not* installed. A dependency's development environment is
# its own choice, so nothing about it is part of initialization.
#
# Inputs (env):
#   REMOTE               default: origin
#   ORIGIN_URL           default: `git remote get-url $REMOTE`
#   MAIN_BRANCH          default: main
#   RELEASE_BRANCH       default: release
#   RELEASE_DIR          default: release
#   CORE_DIR             default: .suede/core   (relative to each branch's root)
#   CORE_URL             default: https://github.com/pmalacho-mit/suede.git
#   MAIN_CORE_BRANCH     default: dependency/main/core
#   RELEASE_CORE_BRANCH  default: dependency/release/core
set -euo pipefail

REMOTE="${REMOTE:-origin}"
MAIN_BRANCH="${MAIN_BRANCH:-main}"
RELEASE_BRANCH="${RELEASE_BRANCH:-release}"
RELEASE_DIR="${RELEASE_DIR:-release}"
CORE_DIR="${CORE_DIR:-.suede/core}"
CORE_URL="${CORE_URL:-https://github.com/pmalacho-mit/suede.git}"
MAIN_CORE_BRANCH="${MAIN_CORE_BRANCH:-dependency/main/core}"
RELEASE_CORE_BRANCH="${RELEASE_CORE_BRANCH:-dependency/release/core}"
ORIGIN_URL="${ORIGIN_URL:-$(git remote get-url "$REMOTE" 2>/dev/null || true)}"

fail() { echo "::error::$*"; exit 1; }

# Refuse rather than clone into something. Every one of these means the
# repository is not in the state initialization assumes, and guessing which way
# it is wrong is how a half-initialized repo happens.
vacant() { # <path>
  [ ! -d "$1" ] || [ -z "$(ls -A "$1" 2>/dev/null)" ] || fail "./$1 already exists and is non-empty"
}

[ -n "$ORIGIN_URL" ] || fail "could not determine the URL of remote '$REMOTE'"
git ls-remote --heads "$ORIGIN_URL" "$RELEASE_BRANCH" | grep -q "refs/heads/${RELEASE_BRANCH}\$" \
  || fail "'$RELEASE_BRANCH' branch not found on $ORIGIN_URL (create the repo with all branches)"

vacant "$CORE_DIR"
vacant "$RELEASE_DIR"

# 1. The maintainer's core, on main. git-subrepo commits each clone itself.
git subrepo clone --branch="$MAIN_CORE_BRANCH" "$CORE_URL" "$CORE_DIR"

# 2. main's ./release folder, tracking this repository's own release branch.
git subrepo clone --branch="$RELEASE_BRANCH" "$ORIGIN_URL" "$RELEASE_DIR"

# 3. The consumer's core, inside ./release so it ships with everything else.
vacant "$RELEASE_DIR/$CORE_DIR"
git subrepo clone --branch="$RELEASE_CORE_BRANCH" "$CORE_URL" "$RELEASE_DIR/$CORE_DIR"

# 4. Publish. A subrepo nested inside ./release leaves behind both a branch
# (`subrepo/release/%2esuede/core`, which makes the ref `subrepo/release`
# uncreatable, since refs are directories) and a scratch directory under
# .git/tmp/subrepo/release (which is where the push wants to put its worktree).
# Neither is a problem a clone hits today, but both are cheap to rule out, and
# push-release.sh clears the same two for the same reason on every publish.
git subrepo clean "$RELEASE_DIR/$CORE_DIR" >/dev/null 2>&1 || true
rm -rf .git/tmp/subrepo
git subrepo push "$RELEASE_DIR"
git push -u "$REMOTE" "$MAIN_BRANCH"
