#!/usr/bin/env bash
# `upstream` waiting for its PR, against a local dependency whose remote looks
# like GitHub, and a stand-in for GitHub's API.
#
# The stand-in is a `curl` first on PATH: it maps a request's URL to a file of
# canned JSON under $FAKE_API (a directory of numbered files is played in
# order, the last one repeating) and logs every URL. The Action itself is not
# run here; what it leaves behind - a PR, a failed run, a deleted branch - is
# what the stand-in and a hook on the remote reproduce.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/../../.." && pwd)"
HARNESS="$ROOT_DIR/.tests/harness"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"
source "$HARNESS/with-local-suede-chain.sh"

HOSTED="$ROOT_DIR/scripts/upstream.sh"
export SUEDE_GITHUB_API="http://api.test" SUEDE_UPSTREAM_INTERVAL=0 SUEDE_UPSTREAM_WAIT=30
WORK=""; OUTPUT=""; STATUS=0; BRANCH=""

setup() {
  WORK="$(mktemp -d)"
  export FAKE_API="$WORK/api"; mkdir -p "$FAKE_API" "$WORK/bin"
  cat > "$WORK/bin/curl" <<'CURL'
#!/usr/bin/env bash
url=""; for a in "$@"; do case "$a" in http*|file*) url="$a" ;; esac; done
case "$url" in file://*) exec /usr/bin/curl "$@" ;; esac
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

  chain_seed_remote "$WORK/bare" "$WORK/seed"
  chain_make_consumer "$WORK/bare" "$WORK/consumer"
  # The dependency's remote, as recorded, is on GitHub; git reaches the bare repo.
  ( cd "$WORK/consumer"
    git config "url.$WORK/bare.insteadOf" https://github.com/owner/foo.git
    git config -f deps/foo/.gitrepo subrepo.remote https://github.com/owner/foo.git
    git commit --quiet -am "record foo's GitHub remote" )
}
cleanup() { [[ -n "$WORK" ]] && rm -rf "$WORK"; }

key() { printf '%s' "$1" | sed 's#[?&=]#_#g'; }
# A change to propose; sets BRANCH to the one upstream will push.
change() { # <text>
  ( cd "$WORK/consumer"
    printf '%s\n' "$1" >> deps/foo/lib/index.js
    git commit --quiet -am "consumer: $1" )
  BRANCH="downstream/consumer-$(git -C "$WORK/consumer" rev-parse HEAD)"
}
respond() { # <path?query> <json> [<json> ...]: a sequence when more than one
  local f="$FAKE_API/$(key "$1")" n=0; shift
  mkdir -p "$(dirname "$f")"
  if [[ $# == 1 ]]; then printf '%s' "$1" > "$f"; return; fi
  mkdir -p "$f"; for body in "$@"; do n=$((n + 1)); printf '%s' "$body" > "$f/$n"; done
}
pulls() { printf 'repos/owner/foo/pulls?head=owner:%s&state=all&per_page=1' "$BRANCH"; }
runs()  { printf 'repos/owner/foo/actions/runs?branch=%s&per_page=1' "$BRANCH"; }
run_json() { # <status> <conclusion or null>
  printf '{"workflow_runs":[{"status":"%s","conclusion":%s,"html_url":"https://github.com/owner/foo/actions/runs/9"}]}' "$1" "$2"
}
propose() { # [args]
  STATUS=0
  OUTPUT="$( cd "$WORK/consumer" && bash "$HOSTED" deps/foo "$@" 2>&1 )" || STATUS=$?
}
calls() { [[ -f "$FAKE_API/.calls" ]] && wc -l < "$FAKE_API/.calls" | tr -d ' ' || echo 0; }
expect() { # <ere> <label>
  if grep -qE -- "$1" <<<"$OUTPUT"; then log_pass "$2"; return 0; fi
  log_failure "$2"; printf '%s\n' "$OUTPUT" | sed 's/^/    /' >&2; return 1
}
expect_status() { [[ "$STATUS" == "$1" ]] && { log_pass "$2"; return 0; }; log_failure "$2 (exit $STATUS)"; printf '%s\n' "$OUTPUT" >&2; return 1; }

prints_the_pr_once_it_opens() {
  change "one"
  respond "$(pulls)" '[]' '[]' '[{"html_url":"https://github.com/owner/foo/pull/7","draft":false}]'
  respond "$(runs)" "$(run_json in_progress null)"
  propose
  expect_status 0 "exits 0" || return 1
  expect 'Waiting for the PR' "says it is waiting" || return 1
  expect '^PR opened:$' "reports the PR" || return 1
  expect 'https://github.com/owner/foo/pull/7' "with its link"
}

a_draft_pr_says_why() {
  change "two"
  respond "$(pulls)" '[{"html_url":"https://github.com/owner/foo/pull/8","draft":true}]'
  propose
  expect_status 0 "exits 0" || return 1
  expect 'PR opened as a draft: replaying your change onto the current release hit conflicts' "says the draft is from conflicts" || return 1
  expect 'https://github.com/owner/foo/pull/8' "with its link"
}

a_failed_action_is_exit_1_with_its_run() {
  change "three"
  respond "$(pulls)" '[]'
  respond "$(runs)" "$(run_json in_progress null)" "$(run_json completed '"failure"')"
  propose
  expect_status 1 "exits 1" || return 1
  expect 'The Action that opens the PR ended: failure' "says the Action failed" || return 1
  expect 'https://github.com/owner/foo/actions/runs/9' "with the run's link"
}

nothing_new_is_reported_when_the_branch_is_removed() {
  # What the Action does when main already has the change: delete the branch.
  cat > "$WORK/bare/hooks/post-receive" <<'HOOK'
#!/bin/sh
while read old new ref; do
  case "$ref" in refs/heads/downstream/*) git update-ref -d "$ref" ;; esac
done
HOOK
  chmod +x "$WORK/bare/hooks/post-receive"
  change "four"
  respond "$(pulls)" '[]'
  respond "$(runs)" "$(run_json completed '"success"')"
  propose
  rm "$WORK/bare/hooks/post-receive"
  expect_status 0 "exits 0" || return 1
  expect 'Nothing new to propose' "says there was nothing new"
}

no_pr_in_time_is_exit_2_with_the_actions_page() {
  change "five"
  respond "$(pulls)" '[]'
  respond "$(runs)" '{"workflow_runs":[]}'
  STATUS=0
  OUTPUT="$( cd "$WORK/consumer" && SUEDE_UPSTREAM_WAIT=0 bash "$HOSTED" deps/foo 2>&1 )" || STATUS=$?
  expect_status 2 "exits 2" || return 1
  expect 'No PR after 0s' "says it gave up waiting" || return 1
  expect 'https://github.com/owner/foo/actions' "with where to look"
}

no_wait_does_not_ask_github() {
  change "six"
  rm -f "$FAKE_API/.calls"
  propose --no-wait
  expect_status 0 "exits 0" || return 1
  expect 'OK Proposed upstream' "proposes as before" || return 1
  [[ "$(calls)" == 0 ]] && log_pass "and asks GitHub nothing" || { log_failure "$(calls) API calls"; return 1; }
}

a_remote_not_on_github_is_not_waited_for() {
  ( cd "$WORK/consumer"
    git config -f deps/foo/.gitrepo subrepo.remote "$WORK/bare"
    git commit --quiet -am "foo at a local path" )
  change "seven"
  rm -f "$FAKE_API/.calls"
  propose
  expect_status 0 "exits 0" || return 1
  expect 'is not on GitHub, so there is no PR to wait for' "says why it does not wait" || return 1
  [[ "$(calls)" == 0 ]] && log_pass "and asks GitHub nothing" || { log_failure "$(calls) API calls"; return 1; }
}

run_test_suite --setup setup --cleanup cleanup \
  prints_the_pr_once_it_opens \
  a_draft_pr_says_why \
  a_failed_action_is_exit_1_with_its_run \
  nothing_new_is_reported_when_the_branch_is_removed \
  no_pr_in_time_is_exit_2_with_the_actions_page \
  no_wait_does_not_ask_github \
  a_remote_not_on_github_is_not_waited_for
