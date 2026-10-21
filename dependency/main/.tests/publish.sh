#!/usr/bin/env bash
# push-release.sh all the way to the release branch, against real local
# repositories initialized the way initialize.yml does it.
#
# What is pinned here is the push itself, not the guard (push-release.sh's own
# test covers that): which remote it goes through, that release/.gitrepo still
# records the URL consumers install from afterwards, and that a push GitHub
# refuses is explained in the job summary.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$TESTS_DIR/../core" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/../../.." && pwd)"
HARNESS="$ROOT_DIR/.tests/harness"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"
source "$HARNESS/with-local-suede-chain.sh"

readonly PUSH_RELEASE="$CORE_DIR/push-release.sh"
readonly INIT="$ROOT_DIR/scripts/actions/init.sh"
export SUEDE_RELEASE_CORE="$ROOT_DIR/dependency/release/core"
export GIT_TERMINAL_PROMPT=0   # an unreachable https://github.com/... must fail, not ask
RECORDED="https://github.com/owner/lib"
WORK=""; OUT=""; STATUS=0; DEP=""; BARE=""

setup() {
  WORK="$(mktemp -d)"
  chain_seed_library_branches "$WORK/suede.git" "$WORK/corework" >/dev/null
}
cleanup() { [[ -n "$WORK" ]] && rm -rf "$WORK"; }

# A fresh, initialized dependency <name>, with one unpublished change under
# release/. Sets DEP (its main checkout) and BARE (its remote).
fresh() { # <name>
  BARE="$WORK/$1.git"; DEP="$WORK/$1"
  chain_seed_remote "$BARE" "$WORK/$1-seed" >/dev/null
  git clone --quiet "$BARE" "$DEP"
  ( cd "$DEP" && git checkout --quiet main
    git config diff.external ''
    ORIGIN_URL="$BARE" CORE_URL="$WORK/suede.git" bash "$INIT" >/dev/null 2>&1
    # As a real dependency records it: the HTTPS URL consumers install from.
    git config -f release/.gitrepo subrepo.remote "$RECORDED"
    git commit --quiet -am "record the HTTPS remote"
    printf 'new\n' > release/lib/new.js
    git add -A && git commit --quiet -m "a change to publish"
    # Only what is on origin is published, so the change goes there first.
    git push --quiet origin main )
}

publish() { # [env assignments are the caller's]
  STATUS=0
  OUT="$( cd "$DEP" && bash "$PUSH_RELEASE" 2>&1 )" || STATUS=$?
}
released() { git --git-dir="$BARE" cat-file -p "release:lib/new.js" 2>/dev/null || true; }
expect() { # <ere> <label> [haystack]
  if grep -qE -- "$1" <<<"${3:-$OUT}"; then log_pass "$2"; return 0; fi
  log_failure "$2"; printf '%s\n' "${3:-$OUT}" | sed 's/^/    /' >&2; return 1
}
lacks() { # <ere> <label>
  if grep -qE -- "$1" <<<"$OUT"; then log_failure "$2"; printf '%s\n' "$OUT" | sed 's/^/    /' >&2; return 1; fi
  log_pass "$2"
}
recorded_after() { # <label>
  local now committed
  now="$(git -C "$DEP" config -f release/.gitrepo --get subrepo.remote)"
  committed="$(git -C "$DEP" config --blob HEAD:release/.gitrepo --get subrepo.remote)"
  [[ "$now" == "$RECORDED" && "$committed" == "$RECORDED" ]] && { log_pass "$1"; return 0; }
  log_failure "$1 (working tree: $now, committed: $committed)"; return 1
}

publishes_through_an_ssh_origin_when_the_recorded_url_is_unreachable() {
  fresh alias
  # A maintainer's clone: origin through an SSH host alias, which git reaches
  # (here, the bare repo). The recorded https://github.com/owner/lib is not
  # reachable at all, so a publish that used it would fail.
  ( cd "$DEP"
    git remote set-url origin git@github.com-work:owner/lib.git
    git config "url.$BARE.insteadOf" git@github.com-work:owner/lib.git )
  publish
  [[ "$STATUS" == 0 ]] && log_pass "the publish succeeds" || { log_failure "exit $STATUS"; printf '%s\n' "$OUT" >&2; return 1; }
  expect 'publishing through origin \(git@github.com-work:owner/lib.git\)' "through origin, and says so" || return 1
  [[ "$(released)" == new ]] && log_pass "the release branch has the change" || { log_failure "release lacks it"; return 1; }
  recorded_after "release/.gitrepo still records $RECORDED, for consumers"
}

an_origin_naming_another_repository_falls_back_to_the_recorded_url() {
  fresh fallback
  git init --quiet --bare "$WORK/elsewhere.git"
  ( cd "$DEP"
    git config "url.$BARE.insteadOf" "$RECORDED"
    git remote set-url origin git@github.com:someone/else.git
    git config "url.$WORK/elsewhere.git.insteadOf" git@github.com:someone/else.git
    git push --quiet origin main )
  publish
  [[ "$STATUS" == 0 ]] && log_pass "the publish succeeds" || { log_failure "exit $STATUS"; printf '%s\n' "$OUT" >&2; return 1; }
  lacks 'publishing through origin' "origin is not used for the release branch" || return 1
  [[ "$(released)" == new ]] && log_pass "the recorded remote's release branch has the change" || { log_failure "release lacks it"; return 1; }
  git --git-dir="$WORK/elsewhere.git" rev-parse -q --verify release >/dev/null \
    && { log_failure "the other repository got a release branch"; return 1; } \
    || log_pass "and the other repository got none"
}

an_origin_that_is_the_recorded_url_rewrites_nothing() {
  fresh ci
  # CI: origin is the recorded HTTPS URL, and a global insteadOf (the token
  # rule) is what reaches it. That rule must keep applying.
  ( cd "$DEP"
    git remote set-url origin "$RECORDED.git"
    git config "url.$BARE.insteadOf" "$RECORDED"
    git config --add "url.$BARE.insteadOf" "$RECORDED.git" )
  publish
  [[ "$STATUS" == 0 ]] && log_pass "the publish succeeds" || { log_failure "exit $STATUS"; printf '%s\n' "$OUT" >&2; return 1; }
  lacks 'publishing through origin' "nothing is rewritten" || return 1
  [[ "$(released)" == new ]] && log_pass "the release branch has the change" || return 1
  recorded_after "release/.gitrepo is unchanged"
}

refuse_release_pushes_with() { # <message>
  cat > "$BARE/hooks/pre-receive" <<HOOK
#!/bin/sh
while read old new ref; do
  if [ "\$ref" = refs/heads/release ]; then echo "$1" >&2; exit 1; fi
done
HOOK
  chmod +x "$BARE/hooks/pre-receive"
}

a_refused_workflow_change_is_explained_in_the_job_summary() {
  fresh workflows
  ( cd "$DEP" && git config "url.$BARE.insteadOf" "$RECORDED" && git remote set-url origin "$RECORDED" )
  local before; before="$(git --git-dir="$BARE" rev-parse release)"
  refuse_release_pushes_with 'refusing to allow a GitHub App to create or update workflow `.github/workflows/suede-downstream-to-main.yml` without `workflows` permission'
  local summary="$WORK/summary.md"; : > "$summary"
  STATUS=0
  OUT="$( cd "$DEP" && GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$summary" bash "$PUSH_RELEASE" 2>&1 )" || STATUS=$?
  [[ "$STATUS" != 0 ]] && log_pass "the publish fails" || { log_failure "exit 0"; return 1; }
  expect '### suede: this release changes a workflow file' "the job summary says why" "$(cat "$summary")" || return 1
  expect 'SUEDE_RELEASE_TOKEN' "and names both fixes" "$(cat "$summary")" || return 1
  expect 'bash .suede/core/push-release.sh' "including publishing by hand" "$(cat "$summary")" || return 1
  [[ "$(git --git-dir="$BARE" rev-parse release)" == "$before" ]] && log_pass "the release branch is untouched" || return 1
}

any_other_refused_push_is_explained_too() {
  fresh refused
  ( cd "$DEP" && git config "url.$BARE.insteadOf" "$RECORDED" && git remote set-url origin "$RECORDED" )
  refuse_release_pushes_with 'protected branch hook declined'
  local summary="$WORK/summary2.md"; : > "$summary"
  STATUS=0
  OUT="$( cd "$DEP" && GITHUB_STEP_SUMMARY="$summary" bash "$PUSH_RELEASE" 2>&1 )" || STATUS=$?
  [[ "$STATUS" != 0 ]] && log_pass "the publish fails" || { log_failure "exit 0"; return 1; }
  expect '### suede: pushing the release branch failed' "the job summary says the push was refused" "$(cat "$summary")" || return 1
  expect 'protected branch hook declined' "with git's own words" "$(cat "$summary")"
}

a_second_publish_with_nothing_new_pushes_nothing() {
  # What makes SUEDE_RELEASE_TOKEN safe: a token's push to main starts another
  # run, which has to find nothing to do rather than push again.
  fresh twice
  ( cd "$DEP" && git config "url.$BARE.insteadOf" "$RECORDED" && git remote set-url origin "$RECORDED" )
  publish
  [[ "$STATUS" == 0 ]] || { log_failure "first publish failed"; printf '%s\n' "$OUT" >&2; return 1; }
  local main release
  main="$(git --git-dir="$BARE" rev-parse main)"; release="$(git --git-dir="$BARE" rev-parse release)"
  publish
  [[ "$STATUS" == 0 ]] && log_pass "a second publish succeeds" || { log_failure "exit $STATUS"; return 1; }
  [[ "$(git --git-dir="$BARE" rev-parse main)" == "$main" && "$(git --git-dir="$BARE" rev-parse release)" == "$release" ]] \
    && log_pass "and pushes nothing to either branch" || { log_failure "a branch moved"; return 1; }
}


# --- publishing only what origin has -------------------------------------------

plain() { # a fresh dependency whose origin is simply the recorded remote
  fresh "$1"
  ( cd "$DEP" && git config "url.$BARE.insteadOf" "$RECORDED" && git remote set-url origin "$RECORDED" )
}
release_tip() { git --git-dir="$BARE" rev-parse release; }
refused_unchanged() { # <ere> <label> <release tip before> <HEAD before>
  [[ "$STATUS" == 1 ]] && log_pass "the publish is refused" || { log_failure "exit $STATUS"; printf '%s\n' "$OUT" >&2; return 1; }
  expect "$1" "$2" || return 1
  [[ "$(release_tip)" == "$3" ]] && log_pass "the release branch is untouched" || { log_failure "release moved"; return 1; }
  [[ "$(git -C "$DEP" rev-parse HEAD)" == "$4" ]] && log_pass "and nothing was committed" || { log_failure "HEAD moved"; return 1; }
}
other_clone_pushes() { # <file under release/lib> <text>
  rm -rf "$WORK/other"; git clone --quiet "$BARE" "$WORK/other"
  ( cd "$WORK/other" && git checkout --quiet main && printf '%s\n' "$2" > "release/lib/$1" \
      && git add -A && git commit --quiet -m "elsewhere: $2" && git push --quiet origin main )
}

a_dirty_tree_is_refused() {
  plain dirty
  local r h; r="$(release_tip)"; h="$(git -C "$DEP" rev-parse HEAD)"
  printf 'uncommitted\n' >> "$DEP/release/lib/index.js"
  publish
  refused_unchanged 'uncommitted changes' "it names the uncommitted changes" "$r" "$h"
}

unpushed_commits_are_refused() {
  plain ahead
  ( cd "$DEP" && printf 'local\n' > release/lib/local.js && git add -A && git commit --quiet -m "not pushed" )
  local r h; r="$(release_tip)"; h="$(git -C "$DEP" rev-parse HEAD)"
  publish
  refused_unchanged 'main has 1 commit\(s\) that are not on origin' "it says main is ahead" "$r" "$h" || return 1
  expect 'Push first' "and to push first"
}

a_main_behind_origin_is_refused_locally() {
  plain behind
  other_clone_pushes elsewhere.js "pushed from elsewhere"
  local r h; r="$(release_tip)"; h="$(git -C "$DEP" rev-parse HEAD)"
  publish
  refused_unchanged 'main is 1 commit\(s\) behind origin' "it says main is behind" "$r" "$h" || return 1
  expect 'Pull first' "and to pull first"
}

in_ci_a_run_behind_origin_publishes_origins_tip() {
  plain ci-behind
  other_clone_pushes elsewhere.js "the newer push"
  STATUS=0
  OUT="$( cd "$DEP" && GITHUB_ACTIONS=true bash "$PUSH_RELEASE" 2>&1 )" || STATUS=$?
  [[ "$STATUS" == 0 ]] && log_pass "the run publishes" || { log_failure "exit $STATUS"; printf '%s\n' "$OUT" >&2; return 1; }
  expect 'main moved on to [0-9a-f]{7} since this run started; publishing that' "it moves to the newer tip, and says so" || return 1
  [[ "$(git --git-dir="$BARE" cat-file -p release:lib/elsewhere.js 2>/dev/null)" == "the newer push" ]] \
    && log_pass "and the newer push is what the release branch has" || { log_failure "release lacks the newer push"; return 1; }
}

a_diverged_main_is_refused() {
  plain diverged
  other_clone_pushes elsewhere.js "theirs"
  ( cd "$DEP" && printf 'mine\n' > release/lib/mine.js && git add -A && git commit --quiet -m "mine" )
  local r h; r="$(release_tip)"; h="$(git -C "$DEP" rev-parse HEAD)"
  publish
  refused_unchanged 'main has diverged from origin' "it says main has diverged" "$r" "$h"
}

a_pin_that_is_not_on_origins_release_is_refused() {
  plain pin
  # Pin a commit origin's release branch does not have, and push that to main:
  # what happens when the release branch was never pushed.
  ( cd "$DEP" && git config -f release/.gitrepo subrepo.commit "$(git rev-parse HEAD)" \
      && git commit --quiet -am "pin something origin's release lacks" && git push --quiet origin main )
  local r h; r="$(release_tip)"; h="$(git -C "$DEP" rev-parse HEAD)"
  publish
  refused_unchanged "pins [0-9a-f]{7}, which is not on the release branch" "it names the unpushed pin" "$r" "$h" || return 1
  expect 'git push origin release' "and the fix"
}

a_dry_run_only_warns() {
  plain dry
  ( cd "$DEP" && printf 'local\n' > release/lib/local.js && git add -A && git commit --quiet -m "not pushed" )
  STATUS=0
  OUT="$( cd "$DEP" && DRY_RUN=1 bash "$PUSH_RELEASE" 2>&1 )" || STATUS=$?
  [[ "$STATUS" == 0 ]] && log_pass "a dry run still passes" || { log_failure "exit $STATUS"; printf '%s\n' "$OUT" >&2; return 1; }
  expect 'warning \(a real publish would refuse\): main has 1 commit' "and warns about the unpushed commit"
}

push_to_main_during_publish() { # <conflicting: 0|1>
  # Lands on main the moment the release branch is pushed: someone pushing
  # while the publish runs.
  cat > "$BARE/hooks/post-receive" <<HOOK
#!/bin/sh
while read old new ref; do
  [ "\$ref" = refs/heads/release ] || continue
  tip=\$(git rev-parse refs/heads/main)
  if [ "$1" = 1 ]; then
    export GIT_INDEX_FILE="\$(mktemp)"
    git read-tree "\$tip"
    blob=\$(printf '[subrepo]\n\tremote = elsewhere\n\tcommit = 0000000\n' | git hash-object -w --stdin)
    git update-index --cacheinfo "100644,\$blob,release/.gitrepo"
    tree=\$(git write-tree)
  else
    tree=\$(git rev-parse "\$tip^{tree}")
  fi
  c=\$(git commit-tree "\$tree" -p "\$tip" -m "a concurrent push" </dev/null)
  git update-ref refs/heads/main "\$c"
done
HOOK
  chmod +x "$BARE/hooks/post-receive"
}

a_concurrent_push_to_main_is_replayed_onto() {
  plain race
  push_to_main_during_publish 0
  publish
  rm "$BARE/hooks/post-receive"
  [[ "$STATUS" == 0 ]] && log_pass "the publish succeeds" || { log_failure "exit $STATUS"; printf '%s\n' "$OUT" >&2; return 1; }
  expect 'moved while publishing; replaying' "it replays its bookkeeping onto the newer main" || return 1
  # Captured first: `git log | grep -q` under pipefail fails whenever grep exits
  # before git has written everything.
  local subjects; subjects="$(git --git-dir="$BARE" log --format=%s main)"
  grep -qx 'a concurrent push' <<<"$subjects" \
    && log_pass "the concurrent push is kept" || { log_failure "the concurrent push was lost"; return 1; }
  [[ "$(git --git-dir="$BARE" config --blob main:release/.gitrepo --get subrepo.commit)" == "$(release_tip)" ]] \
    && log_pass "and main pins the new release" || { log_failure "main does not pin the release tip"; return 1; }
}

a_conflicting_concurrent_push_is_explained() {
  plain clash
  push_to_main_during_publish 1
  local summary="$WORK/summary3.md"; : > "$summary"
  STATUS=0
  OUT="$( cd "$DEP" && GITHUB_STEP_SUMMARY="$summary" bash "$PUSH_RELEASE" 2>&1 )" || STATUS=$?
  rm "$BARE/hooks/post-receive"
  [[ "$STATUS" == 1 ]] && log_pass "the publish exits 1" || { log_failure "exit $STATUS"; printf '%s\n' "$OUT" >&2; return 1; }
  expect '### suede: the release is published, but main could not be updated' "the job summary says what happened" "$(cat "$summary")" || return 1
  [[ "$(git --git-dir="$BARE" cat-file -p release:lib/new.js 2>/dev/null)" == new ]] \
    && log_pass "the release itself went out" || { log_failure "release lacks the change"; return 1; }
}

repo_path_matches_one_repository_across_spellings() {
  local url expected actual failed=0
  while IFS='|' read -r url expected; do
    actual="$(ROOT=/ bash -c 'source "$1"; repo_path "$2"' _ "$CORE_DIR/lib.sh" "$url")"
    if [[ "$actual" == "$expected" ]]; then log_pass "$url -> $actual"; else log_failure "$url -> $actual, expected $expected"; failed=1; fi
  done <<'CASES'
https://github.com/o/r|o/r
https://github.com/o/r.git|o/r
https://github.com/o/r/|o/r
git@github.com:o/r.git|o/r
git@github.com-alias:o/r.git|o/r
ssh://git@github.com/o/r|o/r
https://github.com/Owner/Repo|owner/repo
CASES
  return "$failed"
}

run_test_suite --setup setup --cleanup cleanup \
  publishes_through_an_ssh_origin_when_the_recorded_url_is_unreachable \
  an_origin_naming_another_repository_falls_back_to_the_recorded_url \
  an_origin_that_is_the_recorded_url_rewrites_nothing \
  a_refused_workflow_change_is_explained_in_the_job_summary \
  any_other_refused_push_is_explained_too \
  a_second_publish_with_nothing_new_pushes_nothing \
  a_dirty_tree_is_refused \
  unpushed_commits_are_refused \
  a_main_behind_origin_is_refused_locally \
  in_ci_a_run_behind_origin_publishes_origins_tip \
  a_diverged_main_is_refused \
  a_pin_that_is_not_on_origins_release_is_refused \
  a_dry_run_only_warns \
  a_concurrent_push_to_main_is_replayed_onto \
  a_conflicting_concurrent_push_is_explained \
  repo_path_matches_one_repository_across_spellings
