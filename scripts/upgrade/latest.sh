#!/usr/bin/env bash
# upgrade/latest.sh — migrate a repository created with an earlier version of the
# suede workflow onto the current subrepo layout, where `.suede` and
# `.github/workflows` are each vendored from a dedicated branch of the suede
# library via git-subrepo.
#
# Run from a clean checkout of the consumer repo's `main` branch:
#     bash <(curl -fsSL https://suede.sh/upgrade/latest)
#
# It rewires two branches:
#   release  -> .github/workflows  from dependency/release/-dot-github/workflows
#               .suede             from dependency/release/-dot-suede
#   main     -> .github/workflows  from dependency/main/-dot-github/workflows
#               .suede             from dependency/main/-dot-suede
#
# Obsolete generated files are dropped (the old per-branch workflow on each side,
# plus the one-shot initialize.yml on main). Any consumer-authored files that
# lived under those folders are preserved: each existing folder is set aside,
# the new subrepo is cloned in its place, and the saved files are merged back
# WITHOUT overwriting anything the new subrepo ships.
#
# Inputs (env):
#   SUEDE_REPO_URL default: https://github.com/pmalacho-mit/suede.git
#   REMOTE         default: origin
#   MAIN_BRANCH    default: main
#   RELEASE_BRANCH default: release
#   RELEASE_DIR    default: release   (the release subrepo folder on main)
set -euo pipefail

SUEDE_REPO_URL="${SUEDE_REPO_URL:-https://github.com/pmalacho-mit/suede.git}"
REMOTE="${REMOTE:-origin}"
MAIN_BRANCH="${MAIN_BRANCH:-main}"
RELEASE_BRANCH="${RELEASE_BRANCH:-release}"
RELEASE_DIR="${RELEASE_DIR:-release}"

die() { echo "error: $*" >&2; exit 1; }

# Commit staged/working changes if there are any (git-subrepo refuses a dirty
# tree, so every preparatory mutation has to land as its own commit first).
commit_if_changes() {
  git diff --quiet && git diff --cached --quiet && return 0
  git add -A
  git commit --quiet -m "$1"
}

# Move every file under $1 that does not already exist under $2 into $2, then
# remove $1. Existing files in $2 always win — notably the freshly cloned
# .gitrepo and anything the new subrepo ships — so consumer-authored extras are
# preserved without clobbering the upgrade.
merge_no_overwrite() {
  local src="$1" dst="$2" path rel
  [ -d "$src" ] || return 0
  while IFS= read -r -d '' path; do
    rel="${path#"$src"/}"
    if [ ! -e "$dst/$rel" ]; then
      mkdir -p "$dst/$(dirname "$rel")"
      mv "$path" "$dst/$rel"
    fi
  done < <(find "$src" -type f -print0)
  rm -rf "$src"
}

# Replace a vendored folder with a fresh subrepo clone, preserving extras.
#   $1 dir          target folder (e.g. .suede or .github/workflows)
#   $2 branch       suede library branch to clone from
#   $3 drop_before  file to delete from the EXISTING folder before setting it
#                   aside (the now-obsolete generated workflow); "" to skip
#   $4 drop_after   file to delete from the NEWLY cloned folder; "" to skip
replace_dir() {
  local dir="$1" branch="$2" drop_before="$3" drop_after="$4"
  local bak="${dir}.suede-upgrade-bak"
  [ -e "$bak" ] && die "leftover backup '$bak' exists — remove it and re-run"

  local backed_up=false
  if [ -e "$dir" ]; then
    [ -d "$dir" ] || die "'$dir' exists but is not a directory"
    if [ -n "$drop_before" ] && [ -e "$dir/$drop_before" ]; then
      git rm -q "$dir/$drop_before"
    fi
    if [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
      rm -rf "$dir"                       # nothing worth keeping — let the clone recreate it
    else
      git mv "$dir" "$bak"                # set the consumer's files aside
      backed_up=true
    fi
    commit_if_changes "suede upgrade: set aside existing $dir"
  fi

  mkdir -p "$(dirname "$dir")"
  git subrepo clone "$SUEDE_REPO_URL" "$dir" --branch="$branch"

  if [ -n "$drop_after" ] && [ -e "$dir/$drop_after" ]; then
    git rm -q "$dir/$drop_after"
    commit_if_changes "suede upgrade: drop $dir/$drop_after"
  fi

  if $backed_up; then
    merge_no_overwrite "$bak" "$dir"
    commit_if_changes "suede upgrade: restore preserved files into $dir"
  fi
}

checkout() {
  git checkout --quiet "$1" 2>/dev/null \
    || git checkout --quiet -t "$REMOTE/$1" \
    || die "cannot check out '$1' (no local or $REMOTE branch)"
}

# ---- preconditions ----------------------------------------------------------
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository"
command -v git >/dev/null || die "git not found"
git subrepo --version >/dev/null 2>&1 || die "git-subrepo not installed (see suede README)"

current="$(git rev-parse --abbrev-ref HEAD)"
[ "$current" = "$MAIN_BRANCH" ] || die "must be on '$MAIN_BRANCH' (currently on '$current')"
git diff --quiet && git diff --cached --quiet \
  || die "you have uncommitted changes — commit or stash them, then re-run"

git pull "$REMOTE" "$MAIN_BRANCH"

# ---- release branch ---------------------------------------------------------
echo "Upgrading '$RELEASE_BRANCH' ..."
checkout "$RELEASE_BRANCH"
replace_dir ".github/workflows" "dependency/release/-dot-github/workflows" "subrepo-pull-into-main.yml" ""
replace_dir ".suede"            "dependency/release/-dot-suede"            ""                            ""
git push "$REMOTE" "$RELEASE_BRANCH"

# ---- main branch ------------------------------------------------------------
echo "Upgrading '$MAIN_BRANCH' ..."
checkout "$MAIN_BRANCH"
git subrepo pull "$RELEASE_DIR"          # bring main's release/ folder up to the rebuilt release
replace_dir ".github/workflows" "dependency/main/-dot-github/workflows" "subrepo-push-release.yml" "initialize.yml"
replace_dir ".suede"            "dependency/main/-dot-suede"            ""                          ""
git push "$REMOTE" "$MAIN_BRANCH"

cat <<MSG

OK Upgraded. Both '$RELEASE_BRANCH' and '$MAIN_BRANCH' now vendor .suede and
.github/workflows from the current suede library branches, and have been pushed.
MSG
