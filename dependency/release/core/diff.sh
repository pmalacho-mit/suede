#!/usr/bin/env bash
#
# Show how a suede dependency differs from the commit its .gitrepo names.
#
#   bash diff.sh [<path> ...]      # default: every release dependency
#
# Non-empty output means "this dependency has local modifications", which is
# what subrepo-push-release uses to refuse a dishonest pointer: you ship a
# pointer to code that is not what you built against.
#
# Vendored dependencies (inside release/) are exempt on purpose - a vendored
# dependency exists precisely because it diverges, and it ships as source.
#
# The .gitrepo file itself is excluded: it is local metadata and always differs.

set -euo pipefail

usage() { grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'; exit 0; }
[[ "${1-}" == "-h" || "${1-}" == "--help" ]] && usage

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# Where the remote's copy of a pinned commit is materialised. Under .git/, so
# it can never be committed.
readonly CACHE="$ROOT/.git/suede-diff"

gitrepo_value() { git config -f "$1/.gitrepo" --get "subrepo.$2"; }

release_dependencies() {
  local candidate
  while IFS= read -r candidate; do
    candidate="${candidate%/.gitrepo}"
    candidate="${candidate#./}"
    [[ "$candidate" == release/* ]] && continue   # vendored: exempt
    printf '%s\n' "$candidate"
  done < <(find . -name .gitrepo -not -path './.git/*' -not -path '*/node_modules/*' | sort)
}

# The pinned tree, exported without its .git so the comparison sees only
# content. Cached under .git/ by short sha, so repeated runs are free.
pinned_tree() {
  local path="$1" remote commit branch destination
  remote="$(gitrepo_value "$path" remote)"
  commit="$(gitrepo_value "$path" commit)"
  branch="$(gitrepo_value "$path" branch)"
  destination="$CACHE/${commit:0:7}"
  if [[ ! -f "$destination/.suede-exported" ]]; then
    rm -rf "$destination"
    mkdir -p "$destination"
    git init --quiet "$destination"
    git -C "$destination" remote add origin "$remote"
    git -C "$destination" fetch --quiet --depth 1 origin "$commit" 2>/dev/null \
      || git -C "$destination" fetch --quiet origin "$branch"
    git -C "$destination" checkout --quiet --detach "$commit"
    rm -rf "$destination/.git"
    touch "$destination/.suede-exported"
  fi
  printf '%s\n' "$destination"
}

# The local copy, minus the .gitrepo: that file is local metadata and always
# differs. Copying rather than filtering keeps `git diff` in play, so a
# configured difftool is still honoured.
local_tree() {
  local path="$1" copy
  copy="$(mktemp -d)"
  cp -R "$path/." "$copy/"
  rm -f "$copy/.gitrepo"
  printf '%s\n' "$copy"
}

diff_against_pin() {
  local path="$1" pinned copy status=0
  pinned="$(pinned_tree "$path")"
  copy="$(local_tree "$path")"
  rm -f "$pinned/.suede-exported"
  git diff --no-index --exit-code -- "$pinned" "$copy" || status=$?
  touch "$pinned/.suede-exported"
  rm -rf "$copy"
  return "$status"
}

STATUS=0
for dependency in "${@:-$(release_dependencies)}"; do
  [[ -f "$dependency/.gitrepo" ]] || continue
  if ! diff_against_pin "$dependency"; then
    printf '\ndiff: %s has local modifications relative to %s\n' \
      "$dependency" "$(gitrepo_value "$dependency" commit)" >&2
    STATUS=1
  fi
done
exit "$STATUS"
