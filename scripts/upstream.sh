#!/usr/bin/env bash
# suede upstream — publish a vendored dependency's local changes for REVIEW,
# without ever touching the consumed `release` branch.
#
# HOSTED implementation (serve at e.g. https://suede.sh/upstream). Normally
# invoked by the `.upstream` stub shipped inside a dependency, which passes its
# own folder as the dependency to submit. Power users can call it directly:
#
#     bash <(curl -fsSL https://suede.sh/upstream) <path-to-dependency>
#
# What it does:
#   1. Splits the dependency's local changes via git-subrepo and pushes them to
#      a DETERMINISTIC branch:  submit/<consumer-repo>-<consumer-HEAD>
#      Deterministic => re-running on the same commit re-pushes the same branch
#      (a no-op) instead of creating duplicates.
#   2. Restores local subrepo tracking state so a later `git subrepo pull` is
#      completely safe (no clobber).
#
# A GitHub Action on the dependency turns that branch into a PR to `main`.
# `release` is never modified.

set -euo pipefail

# Keep in sync with the action's  on.push.branches: ["downstream/**"].
BRANCH_PREFIX="downstream"

die() { echo "error: $*" >&2; exit 1; }
usage() {
  cat <<'USAGE'
usage: upstream <path-to-dependency> [-r|--remote <name>]
  Publishes the dependency's local changes for review via a PR to its `main`.
  The dependency's `release` branch is left untouched.
USAGE
}

DIR=""
REMOTE_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)   usage; exit 0 ;;
    -r|--remote) REMOTE_OVERRIDE="${2:-}"; shift 2 ;;
    -*)          die "unknown flag: $1" ;;
    *)           [ -z "$DIR" ] || die "unexpected argument: $1"; DIR="$1"; shift ;;
  esac
done

# ---- locate the dependency and its containing repo --------------------------
[ -n "$DIR" ] || { usage; exit 1; }
command -v git  >/dev/null || die "git not found"
command -v curl >/dev/null || die "curl not found"
git subrepo --version >/dev/null 2>&1 || die "git-subrepo not installed (see suede README)"

DIRABS="$(cd "$DIR" 2>/dev/null && pwd)" || die "no such directory: $DIR"
TOP="$(git -C "$DIRABS" rev-parse --show-toplevel 2>/dev/null)" \
  || die "'$DIR' is not inside a git repository"
cd "$TOP"
RELDIR="${DIRABS#"$TOP"/}"
[ "$RELDIR" != "$DIRABS" ] || die "the dependency must live inside the repo, not at its root"
[ -f "$RELDIR/.gitrepo" ] || die "'$RELDIR' is not a subrepo (no .gitrepo file)"

# Clean tree makes the restore (git reset --hard) a safe, total undo, AND keeps
# consumer-HEAD <-> dependency-state 1:1 (git subrepo push also refuses a dirty tree).
git diff --quiet && git diff --cached --quiet \
  || die "you have uncommitted changes — commit or stash them, then re-run"

# ---- deterministic branch name: <consumer repo>-<consumer HEAD> -------------
remote_url="$(git config --get remote.origin.url 2>/dev/null || true)"
if [ -n "$remote_url" ]; then
  slug="${remote_url%.git}"   # drop trailing .git
  slug="${slug#*://}"         # drop scheme://
  slug="${slug#*@}"           # drop user@  (ssh form)
  slug="${slug#*[:/]}"        # drop host:  or  host/
else
  slug="$(basename "$TOP")"   # no remote -> fall back to repo folder name
fi
# sanitize into a single safe ref segment (owner/name -> owner-name)
slug="$(printf '%s' "$slug" | tr '/' '-' | tr -c 'A-Za-z0-9_.-' '-' \
        | sed -E 's/-+/-/g; s/^[-.]+//; s/[-.]+$//')"
slug="${slug:-repo}"

PRE="$(git rev-parse HEAD)"          # full hash; swap for `--short=12 HEAD` if you want shorter branches
BRANCH="${BRANCH_PREFIX}/${slug}-${PRE}"

echo "Upstreaming '$RELDIR' -> branch '$BRANCH' ..."

# ---- push the split to the branch -------------------------------------------
# No --update: the tracked (pull) branch in .gitrepo stays = release. subrepo
# still makes a local 'finalize' commit + bumps .gitrepo's commit field; we undo
# both below so the tracking pointer keeps referencing `release`.
push_args=(push "$RELDIR" -b "$BRANCH")
[ -n "$REMOTE_OVERRIDE" ] && push_args+=(-r "$REMOTE_OVERRIDE")
git subrepo "${push_args[@]}" \
  || die "subrepo push failed — no write access, or your subdir isn't merged with upstream HEAD"

# ---- restore local state ----------------------------------------------------
git reset --hard "$PRE" >/dev/null

cat <<MSG

OK Upstreamed. Local state restored — safe to 'git subrepo pull' anytime.

  - A PR against the dependency's 'main' will open automatically (branch: $BRANCH).
  - Re-running on this same commit just re-pushes the same branch (no duplicates).
  - The 'release' branch was NOT modified; other consumers are unaffected.
MSG