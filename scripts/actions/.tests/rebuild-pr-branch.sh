#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$(cd "$TESTS_DIR/../../../.tests/harness" && pwd)"
readonly EXTERNAL_REBUILD="https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts/actions/rebuild-pr-branch.sh"
readonly LOCAL_REBUILD="$TESTS_DIR/../rebuild-pr-branch.sh"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"
source "$HARNESS/mock-curl.sh"; source "$HARNESS/with-local-suede-chain.sh"

TEST_DIR=""; BARE=""; BASE0=""; RELEASE_TIP=""
setup() {
  TEST_DIR="$(mktemp -d)"; BARE="$TEST_DIR/dep.git"
  mock_curl_url "$EXTERNAL_REBUILD" "$LOCAL_REBUILD"; enable_url_mocking
  git init --quiet --bare "$BARE"
  local seed="$TEST_DIR/seed"; git init --quiet "$seed"
  ( cd "$seed"; git remote add origin "$BARE"
    printf 'alpha\nbeta\ngamma\n' > lib.txt; git add lib.txt; git commit --quiet -m v0; git branch -m release )
  BASE0="$(git -C "$seed" rev-parse HEAD)"
  ( cd "$seed"; printf 'ALPHA\nbeta\ngamma\n' > lib.txt; git commit --quiet -am v1; git push --quiet origin release )
  RELEASE_TIP="$(git -C "$seed" rev-parse HEAD)"
  ( cd "$seed"; git checkout --quiet --orphan main; git rm -rq --cached . >/dev/null 2>&1 || true; rm -f lib.txt
    mkdir -p src release; printf 'app\n' > src/app.txt; printf 'ALPHA\nbeta\ngamma\n' > release/lib.txt
    printf '[subrepo]\n\tremote = %s\n\tbranch = release\n\tcommit = %s\n' "$BARE" "$RELEASE_TIP" > release/.gitrepo
    git add .; git commit --quiet -m main; git push --quiet origin main )
  git -C "$BARE" symbolic-ref HEAD refs/heads/main
  mk() { ( cd "$seed"; git checkout --quiet -B "ds-$1" "$2"; "$3"; git add -A; git commit --quiet -m "$1" --allow-empty
           git push --quiet --force origin "ds-$1:refs/heads/downstream/$1" ); }
  w_clean()     { printf 'ALPHA\nbeta\ngamma\ndelta\n' > lib.txt; }
  w_nonoverlap(){ printf 'alpha\nbeta\ngamma\ndelta\n' > lib.txt; }
  w_overlap()   { printf 'CONSUMER\nbeta\ngamma\n'     > lib.txt; }
  w_noop()      { :; }
  mk clean-current "$RELEASE_TIP" w_clean
  mk stale-nonoverlap "$BASE0" w_nonoverlap
  mk stale-overlap "$BASE0" w_overlap
  mk noop "$RELEASE_TIP" w_noop
}
cleanup() { [[ -n "${TEST_DIR:-}" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"; disable_url_mocking; }

# Run rebuild for a scenario in a fresh clone. Called directly (NOT via $(...))
# so the cd persists in the test's shell; RESULT is captured into the global RES.
RES=""
_rebuild() { local name="$1"; git clone --quiet "$BARE" "$TEST_DIR/clone-$name" >/dev/null 2>&1
  cd "$TEST_DIR/clone-$name"
  SUBMISSION_REF="downstream/$name" bash <(curl -fsSL "$EXTERNAL_REBUILD") > "$TEST_DIR/rebuild.out" 2>/dev/null
  RES="$(grep RESULT "$TEST_DIR/rebuild.out")"; }

clean_current_applies_on_top_of_release() {
  _rebuild clean-current
  echo "$RES" | grep -q 'conflicted=false has_changes=true' && log_pass "flags: clean, has changes" || { log_failure "flags"; return 1; }
  assert_file_matches release/lib.txt '^ALPHA$' "keeps the upstream change"
  assert_file_matches release/lib.txt '^delta$' "applies the consumer change"
}
stale_nonoverlap_does_not_revert_upstream() {
  _rebuild stale-nonoverlap
  echo "$RES" | grep -q "base=$BASE0" && log_pass "recovered the stale base" || { log_failure "base"; return 1; }
  assert_file_matches release/lib.txt '^ALPHA$' "upstream change PRESERVED (not reverted)"
  assert_file_matches release/lib.txt '^delta$' "consumer change applied"
}
stale_overlap_surfaces_conflict_markers() {
  _rebuild stale-overlap
  echo "$RES" | grep -q 'conflicted=true' && log_pass "conflict detected" || { log_failure "conflict flag"; return 1; }
  assert_file_matches release/lib.txt '^(<{7}|>{7}) ' "conflict markers present"
}
noop_proposes_nothing() {
  _rebuild noop
  echo "$RES" | grep -q 'has_changes=false' && log_pass "no-op detected" || { log_failure "no-op"; return 1; }
}

run_test_suite --setup setup --cleanup cleanup   clean_current_applies_on_top_of_release   stale_nonoverlap_does_not_revert_upstream   stale_overlap_surfaces_conflict_markers   noop_proposes_nothing
