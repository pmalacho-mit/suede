#!/usr/bin/env bash
#
# The whole main-side release flow, so the workflow that calls it can stay a
# caller. Run on `main` after a change under release/ has landed.
#
#   extract -> guard -> commit the manifest -> sync out -> propagate
#
# The guard is the reason this is worth having in one place: a release
# dependency ships as a *pointer*, so before that pointer goes out we check it
# is honest (diff.sh: nothing diverged from its pinned commit) and that every
# declared dependency is actually in place (deps.sh --check, run against
# release/ so it walks the whole tree of siblings). A failure here stops the
# push and writes the reason into the job summary, rather than publishing a
# lie.
#
# Flags:
#   --https              reach every remote over HTTPS only (CI has no SSH key)
#
# Publishing goes through this clone's `origin` when it is the same repository
# as the remote release/.gitrepo records, so a maintainer publishing by hand
# uses the credentials the clone already has (an SSH key, a host alias); the
# recorded HTTPS URL, which consumers install from, is left as it is. A push
# GitHub refuses - most often a release that changes a workflow file, which
# the default Actions token may not push - is explained in the job summary.
#
# Inputs (env):
#   RELEASE_DIR          default: release
#   DRY_RUN              set to 1 to stop before touching the remote
#   SUEDE_RELEASE_CORE   where diff and deps.sh are (default release/.suede/core)

set -euo pipefail
LIB_PREFIX="push-release"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

DRY_RUN="${DRY_RUN:-0}"
CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HTTPS_FLAG=()
for argument in "$@"; do
  case "$argument" in
    --https) HTTPS_FLAG=(--https) ;;
    *) lib_die "unknown argument: $argument" ;;
  esac
done

lib_enter_root
[[ -d "$RELEASE_DIR" ]] || lib_die "no ./$RELEASE_DIR folder - nothing to publish"

# Anything written here also lands in the GitHub job summary, so a maintainer
# reads the reason on the run page rather than in the log.
report() {
  printf '%s\n' "$*" >&2
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"
  return 0
}

# The manifest is generated, never hand-edited, so regenerate it every run and
# commit only when it actually moved.
refresh_manifest() {
  bash "$CORE_DIR/extract.sh"
  git add -A "$RELEASE_DIR/.suede/.dependencies" 2>/dev/null || true
  # --no-ext-diff: a diff.external tool (difftastic, say) would print here.
  if git diff --cached --quiet --no-ext-diff -- "$RELEASE_DIR"; then
    lib_say "manifest unchanged"
    return 0
  fi
  # Only the records: anything else that happens to be staged is not ours to commit.
  git commit --quiet -m "chore(suede): update dependency records" -- "$RELEASE_DIR/.suede/.dependencies"
  lib_say "committed refreshed dependency records"
}

# Two different failures, two different fixes, so they are reported separately.
guard() {
  local failed=0 deps
  # Shipped only: a development dependency ships nothing, and being behind is
  # never a reason to refuse a release.
  if ! bash "$CORE_DIR/diff.sh" --shipped-only ${HTTPS_FLAG[@]+"${HTTPS_FLAG[@]}"} > "$WORKSPACE/diff.txt" 2>&1; then
    report "### suede: a release dependency has diverged from its pin"
    report ''
    report '```'
    report "$(cat "$WORKSPACE/diff.txt")"
    report '```'
    failed=1
  fi
  deps="$(release_tool deps.sh)"
  if ! bash "$deps" --check --in "$RELEASE_DIR" > "$WORKSPACE/deps.txt" 2>&1; then
    report "### suede: a declared dependency is not in place"
    report ''
    report '```'
    report "$(cat "$WORKSPACE/deps.txt")"
    report '```'
    failed=1
  fi
  return "$failed"
}

# Pulling a subrepo nested inside release/ - `.suede/core` is one in every
# dependency - leaves two things behind that stop the push below, in two
# different ways:
#
#   * a branch `subrepo/release/%2esuede/core`. Git refs are directories, so
#     while it exists `subrepo/release` cannot be created: "cannot lock ref".
#   * a scratch directory `.git/tmp/subrepo/release/%2esuede`. That leaves
#     `.git/tmp/subrepo/release` sitting there as an ordinary directory, and
#     the push wants exactly that path for its worktree: "this operation must
#     be run in a work tree".
#
# `git subrepo clean` clears the first and not the second. The pull that causes
# both happens on main, days earlier and by hand, which makes this the only
# place that can be relied on to tidy up after it.
release_nested_subrepos() {
  find "$RELEASE_DIR" -name .gitrepo -not -path "$RELEASE_DIR/.gitrepo" -not -path '*/.git/*' \
    | sed 's#/\.gitrepo$##' | sort
}

clear_nested_subrepo_refs() {
  local nested cleared=0
  while IFS= read -r nested; do
    [[ -n "$nested" ]] || continue
    git subrepo clean "$nested" >/dev/null 2>&1 || true
    cleared=1
  done < <(release_nested_subrepos)
  [[ "$cleared" == 1 ]] || return 0
  lib_say "cleared the git-subrepo leftovers of the subrepos nested in $RELEASE_DIR"
  rm -rf .git/tmp/subrepo
  git worktree prune >/dev/null 2>&1 || true
}

# Pull first so the push lands on top of the current release tip (a release
# that advanced by some other route); "nothing to pull" is not a failure.
# Publish through origin, when origin is this same repository. git-subrepo
# would otherwise use the remote release/.gitrepo records, which is the HTTPS
# URL consumers install from - and a maintainer publishing by hand may have no
# HTTPS credentials at all, only an SSH key (perhaps behind a host alias).
# origin is what this clone already authenticates with.
#
# Done with a one-off insteadOf rather than `-r`: git-subrepo 0.4.9 writes a
# `-r` remote into .gitrepo even without `-u`, and the recorded HTTPS URL is
# what consumers must keep seeing. In CI, origin is that same HTTPS URL, so
# nothing is rewritten and the workflow's token rule applies as before.
#
# Prints the `-c` value to pass to git, or nothing to leave the remote alone.
release_remote_rewrite() {
  local recorded origin target
  recorded="$(git config -f "$RELEASE_DIR/.gitrepo" --get subrepo.remote 2>/dev/null || true)"
  # As configured: get-url would apply insteadOf rules, a token-carrying one in CI.
  origin="$(git config --get remote.origin.pushurl 2>/dev/null || git config --get remote.origin.url 2>/dev/null || true)"
  [[ -n "$recorded" && -n "$origin" ]] || return 0
  [[ "$(repo_path "$origin")" == "$(repo_path "$recorded")" ]] || return 0
  [[ "${origin%.git}" != "${recorded%.git}" ]] || return 0
  # Where git would really push origin, its own rewrites applied: an insteadOf
  # result is not rewritten again, so this has to be the final URL.
  target="$(git remote get-url --push origin)"
  lib_say "publishing through origin ($origin) rather than the recorded $recorded"
  printf 'url.%s.insteadOf=%s' "$target" "$recorded"
}

# Why a push to the release branch failed, in the job summary rather than only
# in a log that needs admin rights to read.
explain_push_failure() { # <push output file>
  if grep -qiE 'refusing to allow .*workflow|without .?workflows.? permission' "$1"; then
    report "### suede: this release changes a workflow file"
    report ''
    report "GitHub refuses a push made with the default Actions token (\`GITHUB_TOKEN\`) that creates or"
    report "changes anything under \`.github/workflows/\` - and this release does, usually because"
    report "\`sync.sh\` brought in an update to \`$RELEASE_DIR/.github/workflows\`. The release branch is unchanged."
    report ''
    report "Either publish from \`main\` on your own machine: \`bash .suede/core/push-release.sh\`"
    report "(it pushes through your clone's \`origin\`, so your SSH key or credentials apply), or give the"
    report "workflow a token that may change workflows: a repository secret \`SUEDE_RELEASE_TOKEN\`"
    report "holding a personal access token with the \`workflow\` scope (or a fine-grained token with"
    report "Contents and Workflows write), then re-run this job."
  else
    report "### suede: pushing the release branch failed"
    report ''
    report "The guard passed; the push itself was refused. The release branch is unchanged. git said:"
    report ''
    report '```'
    report "$(tail -n 20 "$1")"
    report '```'
  fi
}

sync_release_branch() {
  git ${VIA[@]+"${VIA[@]}"} subrepo pull "$RELEASE_DIR" || true
  clear_nested_subrepo_refs
  if ! git ${VIA[@]+"${VIA[@]}"} subrepo push "$RELEASE_DIR" 2>&1 | tee "$WORKSPACE/push.txt"; then
    explain_push_failure "$WORKSPACE/push.txt"
    exit 1
  fi
  push_main
}

# Bring the publish's own commits - the records, and git-subrepo's .gitrepo
# bump - back to main. Someone may have pushed in the meantime; those commits
# are bookkeeping on top of whatever landed, so they are replayed onto the new
# tip and pushed again. A conflict is a real disagreement and stops it.
push_main() {
  local attempt
  for attempt in 1 2 3; do
    git push --quiet origin "HEAD:refs/heads/$BRANCH" && return 0
    lib_say "origin's $BRANCH moved while publishing; replaying the release bookkeeping onto it"
    git fetch -q origin "$BRANCH" || break
    if ! git rebase --quiet "refs/remotes/origin/$BRANCH"; then
      git rebase --abort 2>/dev/null || true
      break
    fi
  done
  report "### suede: the release is published, but $BRANCH could not be updated"
  report ''
  report "The release branch has the new release. Pushing $BRANCH's \`$RELEASE_DIR/.gitrepo\` update failed, and"
  report "replaying it onto origin's newer $BRANCH did not settle it. Nothing is lost: the next publish"
  report "pulls the release branch back into $BRANCH. To do it now: \`git pull\`, then run this again."
  exit 1
}

# What is published has to be exactly what main on GitHub holds: a publish of
# commits GitHub does not have ships code no one can see on main, and one from
# a main that is behind ships a stale tree and then fails to push main. So,
# before anything is committed or pushed:
#
#   * the tree is clean (the records commit would otherwise sweep in whatever
#     else was staged, and git-subrepo refuses a dirty tree halfway through);
#   * HEAD is origin's branch tip, after a fetch. Locally, behind or ahead or
#     diverged is refused with what to do. In CI a run can only be behind - a
#     newer push landed while it queued - and it moves to that tip and
#     publishes it: the newest main is what should ship, and the run queued for
#     that push then finds nothing new;
#   * the release commit release/.gitrepo pins is on the release branch being
#     published to - the recorded remote's, reached the way the push will be.
#
# A dry run checks the same and only warns, so it still works as a guard check
# on work you have not pushed yet.
BRANCH=""
PRECONDITION_FAILED=0
VIA=()   # git -c options that send the release remote through origin (see release_remote_rewrite)
precondition() { # <title> <what to do...>
  if [[ "$DRY_RUN" == "1" ]]; then
    lib_say "warning (a real publish would refuse): $1"
    return 0
  fi
  report "### suede: $1"
  report ''
  shift
  local line; for line in "$@"; do report "$line"; done
  PRECONDITION_FAILED=1
}

check_preconditions() {
  local tip ahead behind pin
  BRANCH="$(git symbolic-ref --short -q HEAD || true)"
  if [[ -z "$BRANCH" ]]; then
    precondition "HEAD is not on a branch" "Check out \`main\` and publish from there."
    return 0
  fi
  if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    precondition "the working tree has uncommitted changes" \
      "Commit or stash them first: \`git status\` lists them."
  fi
  git fetch -q origin "$BRANCH" 2>/dev/null \
    || { precondition "could not fetch $BRANCH from origin" "Check the network and your access, then retry."; return 0; }
  tip="$(git rev-parse "refs/remotes/origin/$BRANCH")"
  ahead="$(git rev-list --count "refs/remotes/origin/$BRANCH..HEAD")"
  behind="$(git rev-list --count "HEAD..refs/remotes/origin/$BRANCH")"
  if [[ "$ahead" -gt 0 && "$behind" -gt 0 ]]; then
    precondition "$BRANCH has diverged from origin" \
      "Yours has $ahead commit(s) origin does not, and origin has $behind you do not ($(short "$tip"))." \
      "Reconcile them (\`git pull\`), push, then publish."
  elif [[ "$ahead" -gt 0 ]]; then
    precondition "$BRANCH has $ahead commit(s) that are not on origin" \
      "Only what is on origin is published. Push first (\`git push\`), then publish."
  elif [[ "$behind" -gt 0 ]]; then
    if [[ "${GITHUB_ACTIONS:-}" == true && "$DRY_RUN" != "1" ]]; then
      lib_say "$BRANCH moved on to $(short "$tip") since this run started; publishing that"
      git merge --quiet --ff-only "refs/remotes/origin/$BRANCH"
    else
      precondition "$BRANCH is $behind commit(s) behind origin ($(short "$tip"))" \
        "Pull first (\`git pull\`), then publish."
    fi
  fi
  # The release branch the publish will push to: the recorded remote, through
  # origin when they are the same repository.
  local rewrite recorded release_tip
  rewrite="$(release_remote_rewrite)"
  [[ -n "$rewrite" ]] && VIA=(-c "$rewrite")
  recorded="$(git config -f "$RELEASE_DIR/.gitrepo" --get subrepo.remote 2>/dev/null || true)"
  pin="$(git config -f "$RELEASE_DIR/.gitrepo" --get subrepo.commit 2>/dev/null || true)"
  [[ -n "$pin" && -n "$recorded" ]] || return 0
  if ! git ${VIA[@]+"${VIA[@]}"} fetch -q "$recorded" release 2>/dev/null; then
    precondition "could not fetch the release branch from $recorded" \
      "Check the network and your access to it, then retry."
    return 0
  fi
  release_tip="$(git rev-parse FETCH_HEAD)"
  if ! { git cat-file -e "$pin^{commit}" 2>/dev/null && git merge-base --is-ancestor "$pin" "$release_tip"; }; then
    precondition "$RELEASE_DIR/.gitrepo pins $(short "$pin"), which is not on the release branch ($(short "$release_tip"))" \
      "The release branch was not pushed. Push it first (\`git push origin release\`), then publish."
  fi
  return 0
}

WORKSPACE="$(mktemp -d)"
trap 'rm -rf "$WORKSPACE"' EXIT

check_preconditions
if [[ "$PRECONDITION_FAILED" == 1 ]]; then
  lib_say "refusing to publish - nothing was committed or pushed"
  exit 1
fi

refresh_manifest

if ! guard; then
  lib_say "refusing to publish - the release branch is unchanged"
  exit 1
fi

[[ "$DRY_RUN" == "1" ]] && { lib_say "dry run: stopping before the push"; exit 0; }
sync_release_branch
lib_say "published $RELEASE_DIR to the release branch"
