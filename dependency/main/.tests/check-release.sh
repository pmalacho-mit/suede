#!/usr/bin/env bash
# check-release.sh and push.sh, against a local repository whose origin looks
# like GitHub, and a stand-in for GitHub's API.
#
# The stand-in is a `curl` first on PATH: it maps a request's URL to a file of
# canned JSON under $FAKE_API (a directory of numbered files is played in
# order, the last one repeating), and logs every URL it was asked for.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$TESTS_DIR/../core" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/../../.." && pwd)"
source "$ROOT_DIR/.tests/harness/runner.sh"; source "$ROOT_DIR/.tests/harness/color-logging.sh"

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export SUEDE_GITHUB_API="http://api.test" SUEDE_CHECK_INTERVAL=0 SUEDE_CHECK_APPEAR=0 SUEDE_CHECK_TIMEOUT=30

WORK=""; OUTPUT=""; STATUS=0
RUNS="repos/owner/lib/actions/workflows/subrepo-push-release.yml/runs"

setup() {
  WORK="$(mktemp -d)"
  export FAKE_API="$WORK/api"; mkdir -p "$FAKE_API" "$WORK/bin"
  cat > "$WORK/bin/curl" <<'CURL'
#!/usr/bin/env bash
url=""; for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
printf '%s\n' "$url" >> "$FAKE_API/.calls"
key="${url#*://*/}"; key="$(printf '%s' "$key" | sed 's#[?&=]#_#g')"
f="$FAKE_API/$key"
if [[ -d "$f" ]]; then
  first="$(ls "$f" | sort -n | head -1)"
  cat "$f/$first"
  [[ "$(ls "$f" | wc -l)" -gt 1 ]] && rm "$f/$first"
  exit 0
fi
[[ -f "$f" ]] && { cat "$f"; exit 0; }
exit 22
CURL
  chmod +x "$WORK/bin/curl"
  export PATH="$WORK/bin:$PATH"

  # origin: a bare repo with a release branch, and main pinning it
  git init -q --bare --initial-branch=main "$WORK/lib.git"
  git init -q --initial-branch=main "$WORK/seed"
  ( cd "$WORK/seed"
    echo v1 > index.ts; git add -A; git commit -qm "release v1"; git branch -m release
    git push -q "$WORK/lib.git" release
    git checkout -q --orphan main; git rm -rq --cached . ; rm -f index.ts
    mkdir release; echo v1 > release/index.ts
    git config -f release/.gitrepo subrepo.remote https://github.com/owner/lib.git
    git config -f release/.gitrepo subrepo.branch release
    git config -f release/.gitrepo subrepo.commit "$(git rev-parse release)"
    echo "# lib" > README.md
    git add -A; git commit -qm "main"; git push -q "$WORK/lib.git" main )
  # the working copy: origin looks like GitHub, and reaches the bare repo
  git clone -q "$WORK/lib.git" "$WORK/repo"
  ( cd "$WORK/repo"
    git remote set-url origin https://github.com/owner/lib.git
    git config "url.$WORK/lib.git.insteadOf" https://github.com/owner/lib.git
    git config diff.external ''
    git fetch -q origin
    mkdir -p .suede/core && cp "$CORE_DIR"/{lib,check-release,push}.sh .suede/core/ )
}
cleanup() { [[ -n "$WORK" ]] && rm -rf "$WORK"; }

# A run for <sha>: the list response, and the run's own endpoint (a sequence).
fake_run() { # <sha> <id> <status:conclusion> ...
  local sha="$1" id="$2" n=0 state; shift 2
  local list="$FAKE_API/$(printf '%s' "$RUNS?head_sha=$sha&per_page=1" | sed 's#[?&=]#_#g')"
  local one="$FAKE_API/repos/owner/lib/actions/runs/$id"
  mkdir -p "$(dirname "$list")" "$one"
  for state in "$@"; do
    n=$((n + 1))
    printf '{"id":%s,"head_sha":"%s","status":"%s","conclusion":%s,"html_url":"https://github.com/owner/lib/actions/runs/%s"}' \
      "$id" "$sha" "${state%%:*}" "$( [[ "$state" == *:* ]] && printf '"%s"' "${state#*:}" || printf null )" "$id" > "$one/$n"
  done
  printf '{"workflow_runs":[%s]}' "$(cat "$one/1")" > "$list"
}
no_runs() { # <sha>
  local list="$FAKE_API/$(printf '%s' "$RUNS?head_sha=$1&per_page=1" | sed 's#[?&=]#_#g')"
  mkdir -p "$(dirname "$list")"; printf '{"workflow_runs":[]}' > "$list"
}
calls() { [[ -f "$FAKE_API/.calls" ]] && wc -l < "$FAKE_API/.calls" | tr -d ' ' || echo 0; }

commit_and_push() { # <file> <text>
  ( cd "$WORK/repo" && mkdir -p "$(dirname "$1")" && echo "$2" > "$1" && git add -A && git commit -qm "$2" && git push -q origin main )
}
check() { # [args]
  STATUS=0
  OUTPUT="$( cd "$WORK/repo" && bash .suede/core/check-release.sh "$@" 2>&1 )" || STATUS=$?
}
tip() { git -C "$WORK/repo" rev-parse HEAD; }
expect() { # <ere> <label>
  if grep -qE -- "$1" <<<"$OUTPUT"; then log_pass "$2"; return 0; fi
  log_failure "$2"; printf '%s\n' "$OUTPUT" | sed 's/^/    /' >&2; return 1
}
expect_status() { [[ "$STATUS" == "$1" ]] && { log_pass "$2"; return 0; }; log_failure "$2 (exit $STATUS)"; printf '%s\n' "$OUTPUT" >&2; return 1; }

a_push_outside_release_does_not_publish() {
  commit_and_push README.md "docs only"
  rm -f "$FAKE_API/.calls"
  check
  expect_status 0 "exits 0" || return 1
  expect 'changed nothing under release/, so it does not publish' "says the push does not publish" || return 1
  [[ "$(calls)" == 0 ]] && log_pass "and asks GitHub nothing" || { log_failure "made $(calls) API calls"; return 1; }
}

a_publishing_push_is_followed_to_success() {
  commit_and_push release/index.ts v2
  fake_run "$(tip)" 101 queued in_progress completed:success
  check
  expect_status 0 "exits 0 when the run succeeds" || return 1
  expect "publish run for [0-9a-f]{7}: https://github.com/owner/lib/actions/runs/101" "prints the run's link" || return 1
  expect 'in_progress' "reports it running" || return 1
  expect 'published: the release branch is at' "and published" || return 1
  expect 'git pull' "with the reminder to pull the .gitrepo update"
}

a_failed_run_exits_1_and_points_at_its_summary() {
  commit_and_push release/index.ts v3
  fake_run "$(tip)" 102 in_progress completed:failure
  check
  expect_status 1 "exits 1 when the run fails" || return 1
  expect 'the publish run ended: failure' "says it failed" || return 1
  expect 'job summary says why: https://github.com/owner/lib/actions/runs/102' "and where the reason is"
}

an_unpushed_release_pin_is_named_before_waiting() {
  # Commit to release locally, pin it from main, push only main: today's mistake.
  ( cd "$WORK/repo"
    git switch -q -c release origin/release
    echo v-local > index.ts; git commit -qam "local release change"
    local pin; pin="$(git rev-parse HEAD)"
    git switch -q main
    git config -f release/.gitrepo subrepo.commit "$pin"
    git commit -qam "pin the local release commit"
    git push -q origin main )
  fake_run "$(tip)" 103 completed:failure
  check
  expect_status 1 "exits 1" || return 1
  expect "pins [0-9a-f]{7}, which is not on GitHub's release branch" "names the unpushed pin" || return 1
  expect 'git push origin release' "and the fix" || return 1
  # put things right for the tests after this one
  ( cd "$WORK/repo" && git push -q origin release )
}

on_its_own_it_reports_mains_latest_commit() {
  # Pushed from elsewhere: this copy's origin/main last moved by fetch, not push.
  git clone -q "$WORK/lib.git" "$WORK/other"
  ( cd "$WORK/other" && echo v4 > release/index.ts && git commit -qam v4 && git push -q origin main )
  local sha; sha="$(git -C "$WORK/other" rev-parse HEAD)"
  ( cd "$WORK/repo" && git fetch -q origin )
  fake_run "$sha" 104 completed:success
  check
  expect_status 0 "exits 0" || return 1
  expect "publish run for ${sha:0:7}" "follows the run for main's latest commit" || return 1
  ( cd "$WORK/repo" && git pull -q --ff-only origin main )
}

no_wait_reports_and_returns() {
  commit_and_push release/index.ts v5
  fake_run "$(tip)" 105 in_progress
  rm -f "$FAKE_API/.calls"
  check --no-wait
  expect_status 0 "exits 0" || return 1
  expect 'still in_progress; run again' "says it is still running" || return 1
  [[ "$(calls)" == 1 ]] && log_pass "after one call" || { log_failure "$(calls) calls"; return 1; }
}

a_run_that_never_appears_is_exit_2() {
  commit_and_push release/index.ts v6
  no_runs "$(tip)"
  check
  expect_status 2 "exits 2" || return 1
  expect 'GitHub has no publish run for [0-9a-f]{7}' "says so" || return 1
  expect 'actions/workflows/subrepo-push-release.yml' "with the workflow's page"
}

a_remote_not_on_github_is_exit_2() {
  git clone -q "$WORK/lib.git" "$WORK/plain"
  cp -R "$WORK/repo/.suede" "$WORK/plain/"
  STATUS=0; OUTPUT="$( cd "$WORK/plain" && bash .suede/core/check-release.sh 2>&1 )" || STATUS=$?
  expect_status 2 "exits 2" || return 1
  expect 'origin is not on GitHub' "and says why"
}

push_sh_pushes_then_checks() {
  ( cd "$WORK/repo" && echo v7 > release/index.ts && git commit -qam v7 )
  fake_run "$(git -C "$WORK/repo" rev-parse HEAD)" 107 completed:success
  STATUS=0; OUTPUT="$( cd "$WORK/repo" && bash .suede/core/push.sh 2>&1 )" || STATUS=$?
  expect_status 0 "push.sh pushed and the publish succeeded" || return 1
  expect 'published' "it followed the run" || return 1
  [[ "$(git -C "$WORK/lib.git" rev-parse main)" == "$(git -C "$WORK/repo" rev-parse HEAD)" ]] \
    && log_pass "and the commit reached origin" || { log_failure "not pushed"; return 1; }
}

push_sh_stops_when_the_push_fails() {
  ( cd "$WORK/other" && git pull -q --ff-only && echo x > README.md && git commit -qam x && git push -q origin main )
  ( cd "$WORK/repo" && echo v8 > release/index.ts && git commit -qam v8 )
  rm -f "$FAKE_API/.calls"
  STATUS=0; OUTPUT="$( cd "$WORK/repo" && bash .suede/core/push.sh 2>&1 )" || STATUS=$?
  [[ "$STATUS" != 0 ]] && log_pass "a rejected push fails push.sh" || { log_failure "exit 0"; return 1; }
  [[ "$(calls)" == 0 ]] && log_pass "and nothing is checked" || { log_failure "$(calls) API calls"; return 1; }
}

run_test_suite --setup setup --cleanup cleanup \
  a_push_outside_release_does_not_publish \
  a_publishing_push_is_followed_to_success \
  a_failed_run_exits_1_and_points_at_its_summary \
  an_unpushed_release_pin_is_named_before_waiting \
  on_its_own_it_reports_mains_latest_commit \
  no_wait_reports_and_returns \
  a_run_that_never_appears_is_exit_2 \
  a_remote_not_on_github_is_exit_2 \
  push_sh_pushes_then_checks \
  push_sh_stops_when_the_push_fails
