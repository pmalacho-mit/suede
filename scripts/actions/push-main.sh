#!/usr/bin/env bash
#
# push-main.sh — push the current branch, yielding to whoever pushed first.
#
# Usage:
#   ./scripts/actions/push-main.sh [BRANCH]      # BRANCH defaults to main
#
# One push to `main` starts several workflows at once, and more than one of them
# writes back to `main`. They check out the same commit within a second of each
# other, so whichever finishes second is pushing a commit whose parent is no
# longer the tip, and git rejects it as a non-fast-forward. The job fails having
# done its real work — the subrepo branch is already pushed — and leaves only
# the bookkeeping behind. That failure is a scheduling accident, not a problem
# with the change, so retry it rather than report it.
#
# Rebase, not merge: what these jobs add on top of `main` is bookkeeping — a
# `.gitrepo` pointer, a generated README block — authored against a commit that
# has nothing to do with whatever landed underneath. Replaying it onto the new
# tip is exactly right, and it keeps `main` free of merge commits nobody chose.
#
# A conflict means the two jobs genuinely disagree about the same lines, which
# no amount of retrying will settle. Abort and fail loudly, leaving the tree
# clean enough to inspect.
#
# Inputs (env):
#   REMOTE           default: origin
#   PUSH_ATTEMPTS    how many times to try before giving up. Default 5, which
#                    is far more than the handful of writers that exist.

set -euo pipefail

readonly REMOTE="${REMOTE:-origin}"
readonly ATTEMPTS="${PUSH_ATTEMPTS:-5}"

usage() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
  exit 0
}

die() { printf 'push-main: %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
  -h|--help) usage ;;
esac

readonly BRANCH="${1:-main}"

for attempt in $(seq 1 "$ATTEMPTS"); do
  if git push "$REMOTE" "HEAD:$BRANCH"; then
    exit 0
  fi

  [[ "$attempt" -lt "$ATTEMPTS" ]] || break

  printf 'push-main: %s moved under us (attempt %d/%d); replaying onto it.\n' \
    "$REMOTE/$BRANCH" "$attempt" "$ATTEMPTS" >&2

  git fetch "$REMOTE" "$BRANCH" ||
    die "could not fetch $REMOTE/$BRANCH; the push failure was not a race."

  git rebase "$REMOTE/$BRANCH" || {
    git rebase --abort || true
    die "rebasing onto $REMOTE/$BRANCH conflicts. Two jobs are writing the same
lines, which is a real disagreement and not something a retry can settle."
  }
done

die "$REMOTE/$BRANCH moved under us $ATTEMPTS times running. Something is
pushing to it continuously; retrying further would only lengthen the loop."
