#!/usr/bin/env bash
# upgrade/latest.sh — migrate a repository created with an earlier version of the
# suede workflow onto the current subrepo layout, where `.suede/core` and
# `.github/workflows` are each vendored from a dedicated branch of the suede
# library via git-subrepo.
#
# Run from a clean checkout of the consumer repo's `main` branch:
#     bash <(curl -fsSL https://suede.sh/upgrade/latest)
#
# Pass --dry-run (or -n, or set DRY_RUN=1) to print exactly what would change on
# the `release` and `main` branches without mutating either. Operations that
# cannot be previewed (notably `git subrepo clone`/`pull`) are described and
# noted as skipped rather than executed.
#
# It rewires two branches:
#   release  -> .github/workflows  from dependency/release/workflows
#               .suede/core        from dependency/release/core
#   main     -> .github/workflows  from dependency/main/workflows
#               .suede/core        from dependency/main/core
#
# Obsolete generated files are dropped (the old per-branch workflow on each side,
# plus the one-shot initialize.yml on main). Any consumer-authored files that
# lived under .github/workflows are preserved: the existing folder is set aside,
# the new subrepo is cloned in its place, and the saved files are merged back
# WITHOUT overwriting anything the new subrepo ships. The new .suede/core subrepo
# is cloned alongside any pre-existing .suede/ files, which are left in place.
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

# Hosted degit utility — used only by --dry-run to fetch the actual contents of
# each subrepo branch so the preview is exact rather than approximate.
SUEDE_SCRIPT_BASE="${SUEDE_SCRIPT_BASE:-https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts}"
DEGIT_URL="${DEGIT_URL:-${SUEDE_SCRIPT_BASE}/utils/degit.sh}"

die() { echo "error: $*" >&2; exit 1; }

usage() {
  cat <<USAGE
usage: latest.sh [--dry-run|-n] [--help|-h]

  --dry-run, -n   describe what would change on '$RELEASE_BRANCH' and
                  '$MAIN_BRANCH' without mutating either branch
  --help, -h      show this help and exit
USAGE
}

# A truthy DRY_RUN env value (anything other than empty/0/false) preselects the
# dry run; --dry-run/-n on the command line forces it on regardless.
case "${DRY_RUN:-}" in
  ""|0|false|no) DRY_RUN=false ;;
  *) DRY_RUN=true ;;
esac
for arg in "${@:-}"; do
  case "$arg" in
    -n|--dry-run) DRY_RUN=true ;;
    -h|--help) usage; exit 0 ;;
    "") ;;
    *) die "unknown argument: $arg (try --help)" ;;
  esac
done

# Dry-run reporting helpers.
plan()      { echo "  + $*"; }                    # a change that would be made
note_skip() { echo "  ~ skipped (not dry-runnable): $*"; }

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
  $DRY_RUN && { plan_replace_dir "$@"; return 0; }
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

# OWNER/REPO slug parsed from SUEDE_REPO_URL (https://host/OWNER/REPO.git).
suede_slug() {
  local s="${SUEDE_REPO_URL#*://}"   # host/OWNER/REPO.git
  s="${s#*/}"                        # OWNER/REPO.git
  printf '%s' "${s%.git}"            # OWNER/REPO
}

# Fetch the tree of a suede library branch into a fresh temp dir via the hosted
# degit utility (no full clone). Echoes the temp dir on success; returns 1 on any
# failure (offline, rate-limited, missing branch) so callers can fall back to the
# approximate report. The fetched tree mirrors the branch exactly — note that the
# real `git subrepo clone` additionally writes a generated .gitrepo, which the
# branch itself does not contain.
degit_fetch() {
  local branch="$1" tmp script
  tmp="$(mktemp -d)" || return 1
  script="$(mktemp)" || { rm -rf "$tmp"; return 1; }
  # Download the utility to a file first: `bash <(curl ...)` silently runs an
  # empty program (exit 0) when curl fails, masking offline/404 errors.
  if ! curl -fsSL "$DEGIT_URL" -o "$script" 2>/dev/null; then
    rm -rf "$tmp" "$script"; return 1
  fi
  # Require a non-empty extraction — a clean exit with no files means the branch
  # could not be fetched, so fall back rather than report "nothing added".
  if bash "$script" --repo "$(suede_slug)" --branch "$branch" --destination "$tmp" \
       >/dev/null 2>&1 && [ -n "$(ls -A "$tmp" 2>/dev/null)" ]; then
    rm -f "$script"
    printf '%s' "$tmp"
  else
    rm -rf "$tmp" "$script"
    return 1
  fi
}

# Exact file-level report for replace_dir, given the new tree fetched into $tmp.
# Whole-file additions/deletions are noted; modified files get a unified diff
# (current consumer copy -> incoming subrepo copy).
report_replace_exact() {
  local dir="$1" drop_before="$2" drop_after="$3" tmp="$4" f rel
  # drop_after is removed from the freshly cloned tree, so exclude it up front.
  [ -n "$drop_after" ] && rm -f "$tmp/$drop_after"

  # Walk the incoming tree: each path is either an add or a modification.
  while IFS= read -r -d '' f; do
    rel="${f#"$tmp"/}"
    if [ -f "$dir/$rel" ]; then
      if cmp -s "$dir/$rel" "$f"; then
        : # identical — no change
      else
        plan "modify '$dir/$rel':"
        diff -u --label "a/$dir/$rel" --label "b/$dir/$rel" "$dir/$rel" "$f" \
          | sed 's/^/      /' || true
      fi
    else
      plan "add '$dir/$rel'"
    fi
  done < <(find "$tmp" -type f -print0)

  # Walk the existing tree for files absent from the incoming tree: either the
  # explicitly dropped obsolete file, or a consumer extra that is preserved.
  if [ -d "$dir" ]; then
    while IFS= read -r -d '' f; do
      rel="${f#"$dir"/}"
      [ -e "$tmp/$rel" ] && continue
      if [ -n "$drop_before" ] && [ "$rel" = "$drop_before" ]; then
        plan "delete obsolete '$dir/$rel'"
      elif [ "$rel" = ".gitrepo" ]; then
        : # replaced by the subrepo-generated .gitrepo (noted below)
      else
        plan "preserve '$dir/$rel' (consumer file, unchanged)"
      fi
    done < <(find "$dir" -type f -print0)
  fi

  plan "write '$dir/.gitrepo' (subrepo metadata, regenerated by the clone)"
}

# Approximate fallback used only when degit_fetch fails: list existing files as
# preservation candidates without knowing exactly what the new subrepo ships.
report_replace_approx() {
  local dir="$1" drop_before="$2" drop_after="$3" f any=false
  note_skip "degit fetch failed (offline/rate-limited) — showing approximate plan"
  if [ -d "$dir" ]; then
    if [ -n "$drop_before" ] && [ -e "$dir/$drop_before" ]; then
      plan "  delete obsolete '$dir/$drop_before'"
    fi
    while IFS= read -r -d '' f; do
      [ -n "$drop_before" ] && [ "$f" = "$dir/$drop_before" ] && continue
      $any || { plan "  preserve existing files (unless the new subrepo ships the same path):"; any=true; }
      plan "    $f"
    done < <(find "$dir" -type f -print0)
    $any || plan "  existing '$dir' has no files to preserve — the clone recreates it"
  else
    plan "  '$dir' does not exist yet — the clone creates it"
  fi
  [ -n "$drop_after" ] && plan "  after clone, delete '$dir/$drop_after' if the subrepo ships it"
}

# Dry-run counterpart to replace_dir (same arguments): report the exact effect of
# rebuilding $dir from $branch, without touching the tree.
plan_replace_dir() {
  local dir="$1" branch="$2" drop_before="$3" drop_after="$4" tmp
  plan "replace '$dir' from subrepo branch '$branch':"
  if [ -e "$dir" ] && [ ! -d "$dir" ]; then
    plan "  WOULD ABORT: '$dir' exists but is not a directory"
    return 0
  fi
  if tmp="$(degit_fetch "$branch")"; then
    report_replace_exact "$dir" "$drop_before" "$drop_after" "$tmp"
    rm -rf "$tmp"
  else
    report_replace_approx "$dir" "$drop_before" "$drop_after"
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

if $DRY_RUN; then
  echo "DRY RUN — no branches will be modified. Planned changes:"
  echo
  note_skip "git pull '$REMOTE' '$MAIN_BRANCH'"
else
  git pull "$REMOTE" "$MAIN_BRANCH"
fi

# ---- release branch ---------------------------------------------------------
echo "Upgrading '$RELEASE_BRANCH' ..."
checkout "$RELEASE_BRANCH"
if $DRY_RUN; then note_skip "git pull"; else git pull; fi
replace_dir ".github/workflows" "dependency/release/workflows" "subrepo-pull-into-main.yml" ""
replace_dir ".suede/core"       "dependency/release/core"      ""                            ""
if $DRY_RUN; then note_skip "git push '$REMOTE' '$RELEASE_BRANCH'"; else git push "$REMOTE" "$RELEASE_BRANCH"; fi

# ---- main branch ------------------------------------------------------------
echo "Upgrading '$MAIN_BRANCH' ..."
checkout "$MAIN_BRANCH"
if $DRY_RUN; then
  # Note-only: this syncs '$RELEASE_DIR/' to the REBUILT '$RELEASE_BRANCH', which
  # does not exist until the release section above is actually pushed — so its
  # exact file-level effect cannot be previewed from current state.
  note_skip "git subrepo pull '$RELEASE_DIR'  (would sync $RELEASE_DIR/ to the rebuilt $RELEASE_BRANCH)"
else
  git subrepo pull "$RELEASE_DIR"          # bring main's release/ folder up to the rebuilt release
fi
replace_dir ".github/workflows" "dependency/main/workflows" "subrepo-push-release.yml" "initialize.yml"
replace_dir ".suede/core"       "dependency/main/core"      ""                          ""

# The release install script moved from scripts/install-release.sh to the nested
# scripts/install/release.sh; repoint the install instructions in the README.
README="README.md"
if [ -f "$README" ] && grep -q 'install-release' "$README"; then
  if $DRY_RUN; then
    plan "rewrite install links in '$README' (install-release -> install/release):"
    grep -n 'install-release' "$README" | while IFS= read -r line; do plan "    $line"; done
  else
    tmp="$(mktemp)"
    sed -e 's#suede\.sh/install-release#suede.sh/install/release#g' \
        -e 's#scripts/install-release\.sh#scripts/install/release.sh#g' \
        "$README" > "$tmp"
    mv "$tmp" "$README"
    commit_if_changes "suede upgrade: point README at install/release"
  fi
fi

if $DRY_RUN; then
  note_skip "git push '$REMOTE' '$MAIN_BRANCH'"
  cat <<MSG

DRY RUN complete — nothing was changed. Re-run without --dry-run to apply.
Note: lines marked "skipped" above (subrepo clone/pull, pull, push) run only in
a real upgrade, and their exact file-level effects cannot be previewed.
MSG
  exit 0
fi

git push "$REMOTE" "$MAIN_BRANCH"

cat <<MSG

OK Upgraded. Both '$RELEASE_BRANCH' and '$MAIN_BRANCH' now vendor .suede and
.github/workflows from the current suede library branches, and have been pushed.
MSG
