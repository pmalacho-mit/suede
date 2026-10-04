#!/usr/bin/env bash
#
# Install a suede dependency into the current directory.
#
#   bash <(curl -fsSL https://suede.sh/install/release) --repo OWNER/REPO
#
# What happens, in order:
#
#   1. The dependency's release branch is resolved and its tree is fetched -
#      no history - into ./<name>, where <name> is the repository's name.
#   2. A .gitrepo is written there, so `sync` and `upstream` work later.
#   3. If this repository is itself a suede dependency (it has release/.gitrepo)
#      and you are running at its root, a symlink <name><sep><repo> -> <name>
#      is created beside the folder - "what it is, then who needs it". When
#      both names start with `suede.` or `suede__`, this repository's prefix is
#      dropped: suede.app installing suede.widget declares suede.widget.app. That symlink is what DECLARES the install
#      a release dependency: `extract` publishes exactly the entries named this
#      way. Delete it and the dependency is a development dependency; rename it
#      to change the separator. Inside release/ nothing is linked, because the
#      source itself ships (a vendored dependency). In a repository that is not
#      a dependency, nothing is linked either, since there is nothing to publish.
#   4. Everything is staged, not committed.
#   5. The dependency's own deps.sh runs, so you see what it needs beside it.
#
# Options:
#   --repo <OWNER/REPO | url>  required. OWNER/REPO means github.com.
#   --at <commit>              install this commit instead of the branch tip
#   --branch <name>            install from this branch (default: release)
#   --sep <text>               separator in the declaring symlink: default __
#                              in a repository named suede__<name>, else .
#                              (__ is for languages where a path segment has
#                              to be an identifier: Python, Rust)
#   --name <folder>            install under this name instead of the repo's
#   --prefix <text>            prepend to the folder name
#   --suffix <text>            append to the folder name
#   --dev                      never create the declaring symlink: a development
#                              dependency (tests, examples), which ships nothing
#   --transitive               never create the declaring symlink: installed for
#                              another dependency's edge, so it ships through
#                              that dependency's record. deps.sh puts this on
#                              every install it prints.
#   --https                    skip the SSH attempt and fetch over HTTPS only -
#                              for a machine you know has no SSH key. The
#                              .gitrepo still records the SSH remote, for
#                              `upstream`. Passed on to deps.sh, so the recipe
#                              it prints carries it too.
#   -h, --help
#
# Remotes: SSH is tried first, so a key is enough for a private repository;
# HTTPS second, so a machine with no key still installs anything public. The
# .gitrepo records the SSH spelling, because that is the one `upstream` can
# push through. Both attempts are quick to fail (BatchMode, 5s connect).
#
# Needs: git. Nothing else - not git-subrepo, not python, and not curl beyond
# the one that fetched this script.
#
# Env:
#   SUEDE_DEPS_URL   where to fetch deps.sh for a dependency that ships without
#                    one (default https://suede.sh/deps)

set -euo pipefail

usage() { grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'; exit 0; }
die()  { printf 'install: %s\n' "$*" >&2; exit 1; }
say()  { printf 'install: %s\n' "$*"; }

RELEASE_DIR="release"
GITREPO_HEADER='; DO NOT EDIT (unless you know what you are doing)
;
; This subdirectory is a git "subrepo", and this file is maintained by the
; git-subrepo command. See https://github.com/ingydotnet/git-subrepo#readme
;'

REPO=""; AT=""; BRANCH="release"; SEP=""; NAME=""; PREFIX=""; SUFFIX=""; DEV=0; TRANSITIVE=0; HTTPS_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)   usage ;;
    -r|--repo)   REPO="${2-}";   shift 2 ;;
    --at)        AT="${2-}";     shift 2 ;;
    --branch)    BRANCH="${2-}"; shift 2 ;;
    --sep)       SEP="${2-}";    shift 2 ;;
    --name)      NAME="${2-}";   shift 2 ;;
    --prefix)    PREFIX="${2-}"; shift 2 ;;
    --suffix)    SUFFIX="${2-}"; shift 2 ;;
    --dev)       DEV=1;          shift ;;
    --transitive) TRANSITIVE=1;  shift ;;
    --https)     HTTPS_ONLY=1;   shift ;;
    *)           die "unknown argument: $1 (see --help)" ;;
  esac
done
[[ -n "$REPO" ]]   || die "--repo is required"
[[ "$DEV" == 1 && "$TRANSITIVE" == 1 ]] && die "--dev and --transitive say two different things; pick one"
[[ -n "$BRANCH" ]] || die "--branch needs a name"

command -v git >/dev/null 2>&1 || die "git not found"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
ROOT="$(cd "$ROOT" && pwd -P)"
HERE="$(pwd -P)"

# --- remotes ----------------------------------------------------------------
# The two spellings of one repository. host/path are empty for anything that
# is not a hosted owner/name repository (a local path, file://), which then has
# exactly one spelling: itself.
HOST=""; PATH_PART=""
case "$REPO" in
  http://*|https://*)
    rest="${REPO#*://}"; HOST="${rest%%/*}"; PATH_PART="${rest#*/}" ;;
  ssh://*)
    rest="${REPO#ssh://}"; rest="${rest#*@}"; HOST="${rest%%/*}"; PATH_PART="${rest#*/}" ;;
  *@*:*)
    rest="${REPO#*@}"; HOST="${rest%%:*}"; PATH_PART="${rest#*:}" ;;
  */*)
    # OWNER/REPO shorthand: no scheme, no colon, not a path on disk.
    if [[ "$REPO" != /* && "$REPO" != .* && ! -e "$REPO" && "${REPO#*/}" != */* ]]; then
      HOST="github.com"; PATH_PART="$REPO"
    fi ;;
esac
PATH_PART="${PATH_PART%/}"; PATH_PART="${PATH_PART%.git}"

if [[ -n "$HOST" && -n "$PATH_PART" ]]; then
  SSH_URL="git@$HOST:$PATH_PART.git"
  HTTPS_URL="https://$HOST/$PATH_PART.git"
  CANDIDATES=("$SSH_URL" "$HTTPS_URL")
  [[ "$HTTPS_ONLY" == 1 ]] && CANDIDATES=("$HTTPS_URL")
  RECORDED_REMOTE="$SSH_URL"
else
  CANDIDATES=("$REPO")
  RECORDED_REMOTE="$REPO"
fi

# Our own git calls fail fast and never prompt; the user's later `git subrepo`
# calls are separate processes and keep their own configuration.
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=5}"
export GIT_TERMINAL_PROMPT=0

FETCH_URL=""; TIP=""
for candidate in "${CANDIDATES[@]}"; do
  if TIP="$(git ls-remote --exit-code "$candidate" "refs/heads/$BRANCH" 2>/dev/null | cut -f1)"; then
    FETCH_URL="$candidate"; break
  fi
  [[ ${#CANDIDATES[@]} -gt 1 && "$candidate" == "${CANDIDATES[0]}" ]] \
    && say "ssh to $HOST did not answer; trying https"
done
[[ -n "$FETCH_URL" ]] || die "could not find branch '$BRANCH' at ${CANDIDATES[*]}"
COMMIT="${AT:-$TIP}"

# --- naming -----------------------------------------------------------------
default_name="${PATH_PART:-${REPO%/}}"; default_name="${default_name%.git}"; default_name="${default_name##*[:/]}"
NAME="${PREFIX}${NAME:-$default_name}${SUFFIX}"
[[ "$NAME" != */* && "$NAME" != . && "$NAME" != .. ]] || die "'$NAME' is not a valid folder name"
DEST="$HERE/$NAME"
if [[ -e "$DEST" || -L "$DEST" ]]; then
  die "./$NAME already exists. To install beside it, pick another name: --name <folder>, --prefix <text> or --suffix <text>"
fi

# --- where are we -----------------------------------------------------------
if git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
  REPO_NAME="$(git -C "$ROOT" remote get-url origin)"
  REPO_NAME="${REPO_NAME%/}"; REPO_NAME="${REPO_NAME%.git}"; REPO_NAME="${REPO_NAME##*[:/]}"
else
  REPO_NAME="$(basename "$ROOT")"
fi

# A repository named suede__<name> is one where a period cannot appear in an
# import (Python), so its separator is `__`; every other repository uses `.`.
# --sep overrides either way.
if [[ -z "$SEP" ]]; then
  if [[ "$REPO_NAME" == suede__?* ]]; then SEP="__"; else SEP="."; fi
fi

IS_DEPENDENCY_REPO=0; [[ -f "$ROOT/$RELEASE_DIR/.gitrepo" ]] && IS_DEPENDENCY_REPO=1
INSIDE_RELEASE=0
[[ "$IS_DEPENDENCY_REPO" == 1 && ( "$HERE" == "$ROOT/$RELEASE_DIR" || "$HERE" == "$ROOT/$RELEASE_DIR/"* ) ]] && INSIDE_RELEASE=1

# The declaring symlink reads "what it is, then who needs it":
# <dependency><sep><this repo>. Suede repositories are named `suede.<name>` (or
# `suede__<name>` where a period cannot appear in an import), and when the
# dependency carries that prefix this repository's copy of it says nothing, so
# it is dropped: suede.svelte-testing-utility installing
# suede.typescript-testing-utility declares
# suede.typescript-testing-utility.svelte-testing-utility.
dependent_name() {
  local prefix
  if [[ "$default_name" == suede.?* || "$default_name" == suede__?* ]]; then
    for prefix in "suede." "suede__"; do
      [[ "$REPO_NAME" == "$prefix"?* ]] && { printf '%s' "${REPO_NAME#"$prefix"}"; return; }
    done
  fi
  printf '%s' "$REPO_NAME"
}

LINK=""
if [[ "$INSIDE_RELEASE" == 1 ]]; then
  MODE="vendored"
elif [[ "$IS_DEPENDENCY_REPO" == 0 ]]; then
  MODE="plain"
elif [[ "$DEV" == 1 ]]; then
  MODE="development"
elif [[ "$TRANSITIVE" == 1 ]]; then
  MODE="transitive"
elif [[ "$HERE" != "$ROOT" ]]; then
  die "a release dependency has to sit beside $RELEASE_DIR/: code in $RELEASE_DIR/ reaches it as ../$NAME$SEP$(dependent_name), and that path only holds at the repository root.
  Run this from $ROOT, or pass --dev or --transitive to install here without declaring it."
else
  MODE="release"
  LINK="$HERE/$NAME$SEP$(dependent_name)"
fi

# --- fetch ------------------------------------------------------------------
WORKSPACE="$(mktemp -d)"
trap 'rm -rf "$WORKSPACE"' EXIT

say "$REPO, $BRANCH @ ${COMMIT:0:7}  ->  ./$NAME"
git init --quiet "$WORKSPACE/tree"
git -C "$WORKSPACE/tree" remote add origin "$FETCH_URL"
# A bare SHA is refused by some servers; the branch always works.
git -C "$WORKSPACE/tree" fetch --quiet --depth 1 origin "$COMMIT" 2>/dev/null \
  || git -C "$WORKSPACE/tree" fetch --quiet origin "refs/heads/$BRANCH" \
  || die "could not fetch from $FETCH_URL"
git -C "$WORKSPACE/tree" checkout --quiet --detach "$COMMIT" 2>/dev/null \
  || die "$FETCH_URL has no commit $COMMIT on $BRANCH"
COMMIT="$(git -C "$WORKSPACE/tree" rev-parse HEAD)"
rm -rf "$WORKSPACE/tree/.git" "$WORKSPACE/tree/.gitrepo"

mkdir "$DEST"
cp -R "$WORKSPACE/tree/." "$DEST/"

# The .gitrepo git-subrepo would have written, minus the merge it would have
# made: `parent` is this repository's HEAD, which is what `git subrepo pull`
# later uses as the base.
PARENT="$(git -C "$ROOT" rev-parse --verify HEAD 2>/dev/null || true)"
printf '%s\n' "$GITREPO_HEADER" > "$DEST/.gitrepo"
git config -f "$DEST/.gitrepo" subrepo.remote "$RECORDED_REMOTE"
git config -f "$DEST/.gitrepo" subrepo.branch "$BRANCH"
git config -f "$DEST/.gitrepo" subrepo.commit "$COMMIT"
git config -f "$DEST/.gitrepo" subrepo.parent "$PARENT"
git config -f "$DEST/.gitrepo" subrepo.method "merge"
git config -f "$DEST/.gitrepo" subrepo.cmdver "0.4.9"

git -C "$ROOT" add -- "$DEST"

# --- declare ----------------------------------------------------------------
case "$MODE" in
  release)
    if [[ -e "$LINK" || -L "$LINK" ]]; then
      say "$(basename "$LINK") already exists; leaving it as it is"
    else
      ln -s "$NAME" "$LINK"
      git -C "$ROOT" add -- "$LINK"
      say "declared as a release dependency of $REPO_NAME:"
      say "  $(basename "$LINK") -> $NAME"
      say "  (delete that symlink to make it a development dependency; rename it to change the separator)"
    fi ;;
  development)
    say "not declared (--dev): $REPO_NAME's consumers will not hear about it" ;;
  transitive)
    say "not declared (--transitive): it is here because another dependency needs it, and"
    say "  the recipe links that dependency's edge to it. It ships through that dependency's"
    say "  own record, and the publish guard still checks it for local changes."
    if [[ "$HERE" == "$ROOT" ]]; then
      say "  If $REPO_NAME's own $RELEASE_DIR/ code imports it as well, declare it:"
      say "    ln -s $NAME $NAME$SEP$(dependent_name)"
    fi ;;
  vendored)
    say "inside $RELEASE_DIR/ of $REPO_NAME: installed as vendored source, nothing to declare" ;;
  plain)
    say "$REPO_NAME is not a suede dependency (no $RELEASE_DIR/.gitrepo), so nothing is declared" ;;
esac
say "staged, not committed"

# --- what does it need ------------------------------------------------------
echo
DEPS_ARGS=()
[[ "$HTTPS_ONLY" == 1 ]] && DEPS_ARGS=(--https)
SHIPPED_DEPS="$DEST/.suede/core/deps.sh"
# A dependency published before --https existed ships a deps.sh that would
# refuse the flag; the hosted one takes it.
if [[ -f "$SHIPPED_DEPS" ]] && { [[ "$HTTPS_ONLY" == 0 ]] || grep -q -- '--https)' "$SHIPPED_DEPS"; }; then
  bash "$SHIPPED_DEPS" ${DEPS_ARGS[@]+"${DEPS_ARGS[@]}"} || true
elif [[ -f "$SHIPPED_DEPS" ]] || ls "$DEST/.suede/.dependencies"/*.gitrepo >/dev/null 2>&1; then
  if command -v curl >/dev/null 2>&1; then
    bash <(curl -fsSL "${SUEDE_DEPS_URL:-https://suede.sh/deps}") --in "$DEST" ${DEPS_ARGS[@]+"${DEPS_ARGS[@]}"} || true
  else
    say "$NAME has dependencies of its own under .suede/.dependencies but ships no deps.sh; see https://suede.sh/deps"
  fi
else
  say "$NAME needs nothing beside it"
fi
