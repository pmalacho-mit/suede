#!/usr/bin/env bash
# suede upstream — propose a vendored dependency's local changes to the library
# upstream as a reviewable PR, without ever touching the consumed `release` branch.
#
# HOSTED implementation (serve at https://suede.sh/upstream). Normally invoked
# by the `.suede/upstream` stub shipped inside a dependency, which passes the
# dependency root as the argument. Direct use:
#     bash <(curl -fsSL https://suede.sh/upstream) <path-to-dependency>
#
# It splits the dependency's local changes via git-subrepo and pushes them to a
# deterministic branch  downstream/<consumer-repo>-<consumer-HEAD>  on the
# dependency's remote. A GitHub Action on the dependency then rebuilds that
# branch in place as a main-shaped PR head for the maintainers to test & merge.
# `release` is never modified, and local subrepo tracking is restored so a later
# `git subrepo pull` is safe.

set -euo pipefail

# Keep in sync with the action's  on.push.branches: ["downstream/**"].
BRANCH_PREFIX="downstream"

die() { echo "error: $*" >&2; exit 1; }
usage() {
  cat <<'USAGE'
usage: upstream <path-to-dependency> [-r|--remote <name>]
  Proposes the dependency's local changes upstream via a PR to its `main`.
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

# Clean tree => the restore (git reset --hard) is a safe total undo, AND keeps
# consumer-HEAD <-> dependency-state 1:1 (git subrepo push also refuses a dirty tree).
git diff --quiet && git diff --cached --quiet \
  || die "you have uncommitted changes — commit or stash them, then re-run"

# ---- deterministic branch name: <consumer repo>-<consumer HEAD> -------------
remote_url="$(git config --get remote.origin.url 2>/dev/null || true)"
if [ -n "$remote_url" ]; then
  slug="${remote_url%.git}"; slug="${slug#*://}"; slug="${slug#*@}"; slug="${slug#*[:/]}"
else
  slug="$(basename "$TOP")"
fi
slug="$(printf '%s' "$slug" | tr '/' '-' | tr -c 'A-Za-z0-9_.-' '-' \
        | sed -E 's/-+/-/g; s/^[-.]+//; s/[-.]+$//')"
slug="${slug:-repo}"

PRE="$(git rev-parse HEAD)"        # full hash; use `--short=12 HEAD` for shorter branch names
BRANCH="${BRANCH_PREFIX}/${slug}-${PRE}"

# ---- pre-flight: already proposed this exact snapshot? ----------------------
dep_remote="${REMOTE_OVERRIDE:-$(git config -f "$RELDIR/.gitrepo" subrepo.remote 2>/dev/null || true)}"
if [ -n "$dep_remote" ] && git ls-remote --heads --exit-code "$dep_remote" "$BRANCH" >/dev/null 2>&1; then
  die "this exact snapshot (commit ${PRE}) is already proposed — see the open PR for '$BRANCH'"
fi

echo "Proposing '$RELDIR' upstream -> branch '$BRANCH' ..."

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

OK Proposed upstream. Local state restored — safe to 'git subrepo pull' anytime.

  - A PR against the dependency's 'main' opens automatically (branch: $BRANCH).
  - The maintainers own that branch from here: they may test and push to it.
  - Further local changes become a NEW snapshot/branch/PR (one-off per commit).
  - The 'release' branch was NOT modified; other consumers are unaffected.
MSG