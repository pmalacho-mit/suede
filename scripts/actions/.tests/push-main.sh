#!/usr/bin/env bash
# What `push-main.sh` does when main moves under it.
#
# The scenario is the one that took CI down three times: two jobs check out the
# same commit, both commit on top of it, and the slower one's push is rejected.
# It is reproduced with two clones of one bare remote rather than with two
# workflows, because two clones is all a non-fast-forward ever is.
#
# Each test rebuilds the remote from scratch. These tests race deliberately, and
# a scenario left behind by the previous one is exactly the kind of state that
# makes a racing test lie.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$(cd "$TESTS_DIR/../../../.tests/harness" && pwd)"
readonly PUSH_MAIN="$TESTS_DIR/../push-main.sh"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"

TEST_DIR=""
BARE=""
OURS=""      # the job under test
THEIRS=""    # the job that gets there first

setup() { TEST_DIR="$(mktemp -d)"; }
cleanup() { [[ -n "${TEST_DIR:-}" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"; }

scenario() {
  local room; room="$(mktemp -d "$TEST_DIR/case-XXXX")"
  BARE="$room/remote.git"
  OURS="$room/ours"
  THEIRS="$room/theirs"

  git init --quiet --bare --initial-branch=main "$BARE"
  git init --quiet --initial-branch=main "$room/seed"
  ( cd "$room/seed"
    git config user.email seed@test; git config user.name seed
    printf 'one\n' > shared.txt
    printf 'pointer = a\n' > pointer.txt
    git add -A && git commit --quiet -m "seed"
    git push --quiet "$BARE" main )

  git clone --quiet "$BARE" "$OURS"
  git clone --quiet "$BARE" "$THEIRS"
  local clone
  for clone in "$OURS" "$THEIRS"; do
    git -C "$clone" config user.email job@test
    git -C "$clone" config user.name job
  done
}

# The other job lands a commit on main.
they_push() { # <file> <contents>
  ( cd "$THEIRS"
    git pull --quiet --rebase
    printf '%s\n' "$2" > "$1"
    git add -A && git commit --quiet -m "theirs: $1"
    git push --quiet )
}

we_commit() { # <file> <contents>
  ( cd "$OURS"
    printf '%s\n' "$2" > "$1"
    git add -A && git commit --quiet -m "ours: $1" )
}

push_main() { ( cd "$OURS" && bash "$PUSH_MAIN" "$@" ); }

remote_log() { git --git-dir="$BARE" log --format='%s' main; }

a_clean_push_is_left_alone() {
  scenario
  we_commit pointer.txt "pointer = b"

  if ! push_main >/dev/null 2>&1; then
    log_failure "an unopposed push failed"; return 1
  fi
  [[ "$(remote_log | head -1)" == "ours: pointer.txt" ]] \
    && log_pass "an unopposed push behaves like git push" \
    || { log_failure "the commit did not reach the remote"; return 1; }
}

a_commit_that_landed_first_is_rebased_onto() {
  scenario
  we_commit pointer.txt "pointer = b"
  they_push notes.md "banner"

  if ! push_main >/dev/null 2>&1; then
    log_failure "the retry did not recover the race"; return 1
  fi
  if [[ "$(remote_log | head -2 | tr '\n' ' ')" == "ours: pointer.txt theirs: notes.md " ]]; then
    log_pass "ours replayed on top of theirs, and both survived"
  else
    log_failure "unexpected history: $(remote_log | tr '\n' ' ')"; return 1
  fi
}

# Replaying, not merging: main stays linear, and no merge commit nobody chose.
nothing_merges() {
  scenario
  we_commit pointer.txt "pointer = b"
  they_push notes.md "banner"

  if ! push_main >/dev/null 2>&1; then
    log_failure "the retry did not recover the race"; return 1
  fi

  local merges; merges="$(git --git-dir="$BARE" log --merges --format='%s' main)"
  [[ -z "$merges" ]] \
    && log_pass "main is still linear" \
    || { log_failure "a merge commit was created: $merges"; return 1; }
}

# Losing the race twice is still a race. A pre-push hook lands a competing
# commit in the window between our fetch and our push, so the first two attempts
# are rejected however promptly we replay.
it_keeps_yielding_until_it_gets_through() {
  scenario
  printf '0\n' > "$TEST_DIR/races"
  cat > "$OURS/.git/hooks/pre-push" <<HOOK
#!/usr/bin/env bash
raced="\$(cat "$TEST_DIR/races")"
if [[ "\$raced" -lt 2 ]]; then
  printf '%d\n' "\$((raced + 1))" > "$TEST_DIR/races"
  cd "$THEIRS"
  git pull --quiet --rebase
  printf 'again\n' > "theirs-\$raced.md"
  git add -A && git commit --quiet -m "theirs: round \$raced"
  git push --quiet
fi
exit 0
HOOK
  chmod +x "$OURS/.git/hooks/pre-push"
  we_commit pointer.txt "pointer = b"

  if ! push_main >/dev/null 2>&1; then
    log_failure "two lost races was one too many"; return 1
  fi
  [[ "$(remote_log | head -1)" == "ours: pointer.txt" ]] \
    && log_pass "it replays as many times as it takes ($(cat "$TEST_DIR/races") races lost)" \
    || { log_failure "unexpected history: $(remote_log | tr '\n' ' ')"; return 1; }
}

# A real disagreement is not a scheduling accident. Fail, and leave no rebase
# half-applied for whatever runs next.
a_conflict_fails_loudly_and_cleanly() {
  scenario
  we_commit shared.txt "ours"
  they_push shared.txt "theirs"

  if push_main >/dev/null 2>&1; then
    log_failure "a conflicting push reported success"; return 1
  fi
  log_pass "a conflict fails the job"

  if [[ -d "$OURS/.git/rebase-merge" || -d "$OURS/.git/rebase-apply" ]]; then
    log_failure "it left a rebase in progress"; return 1
  fi
  log_pass "and leaves no rebase in progress"
}

# Every retry costs a fetch. The cap is what stops a job whose push can never
# succeed from spinning until the runner times out.
it_gives_up_rather_than_spinning() {
  scenario
  we_commit pointer.txt "pointer = b"
  git -C "$OURS" remote set-url --push origin "$TEST_DIR/nowhere.git"

  if PUSH_ATTEMPTS=2 push_main >/dev/null 2>&1; then
    log_failure "a push that can never succeed reported success"; return 1
  fi
  log_pass "it gives up instead of retrying forever"
}

run_test_suite --setup setup --cleanup cleanup \
  a_clean_push_is_left_alone \
  a_commit_that_landed_first_is_rebased_onto \
  nothing_merges \
  it_keeps_yielding_until_it_gets_through \
  a_conflict_fails_loudly_and_cleanly \
  it_gives_up_rather_than_spinning
