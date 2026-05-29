#!/usr/bin/env bash
# push-release.sh — core of subrepo-push-release.yml. Run on `main` after a
# change under release/ has landed. Syncs ./release out to the `release` branch
# via a real subrepo push, then propagates the updated .gitrepo pointer back to
# main. (Checkout, credentials, git-subrepo install, and the .dependencies/
# artifact population stay configured in the action.)
#
# Inputs (env): RELEASE_DIR (default: release)
set -euo pipefail
RELEASE_DIR="${RELEASE_DIR:-release}"

# Pull first so our push lands on top of the current release tip (handles a
# release that advanced via some other merge); tolerate "nothing to pull".
git subrepo pull "$RELEASE_DIR" || true
git subrepo push "$RELEASE_DIR"
git push                          # propagate the .gitrepo pointer bump back to main
