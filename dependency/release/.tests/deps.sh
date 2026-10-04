#!/usr/bin/env bash
# The consumer-side `deps.sh`, against real local repositories.
#
# It reads records and prints commands; what has to come out right is which
# of the four outcomes each record gets (satisfied, reuse, decide, install),
# that the recipe is complete up front, and that `--check` is an honest exit
# code. Runs on bash 3.2, because consumers do.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/../../.." && pwd)"
HARNESS="$ROOT_DIR/.tests/harness"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"
source "$HARNESS/with-suede-graph.sh"
source "$HARNESS/ssh-spy.sh"

INSTALL="$ROOT_DIR/scripts/install/release.sh"
export SUEDE_INSTALL_URL="file://$INSTALL"

WORK=""; MIXIN=""; MIXIN_V2=""; DOCKVIEW=""; OUTPUT=""; STATUS=0

# mixin <- dockview <- sweater, with sweater also wanting mixin directly: a
# diamond, which is where "same install as" and reuse show up.
setup() {
  WORK="$(mktemp -d)"
  MIXIN="$(graph_make_dep "$WORK" mixin)"
  DOCKVIEW="$(graph_make_dep "$WORK" dockview "mixin.dockview=$(graph_remote "$WORK" mixin)@$MIXIN")"
  graph_make_dep "$WORK" sweater \
    "dockview.sweater=$(graph_remote "$WORK" dockview)@$DOCKVIEW" \
    "mixin.sweater=$(graph_remote "$WORK" mixin)@$MIXIN" >/dev/null
  graph_make_dep "$WORK" other "mixin.other=$(graph_remote "$WORK" mixin)@$MIXIN" >/dev/null
  graph_make_project "$WORK" app --dependency
  ( cd "$WORK/app" && bash "$INSTALL" --repo "$(graph_remote "$WORK" sweater)" >/dev/null 2>&1 )
  # A newer mixin release than anything above pins, for the "different commit"
  # cases. Computed here because each test runs in its own subshell.
  MIXIN_V2="$(graph_advance_dep "$WORK" mixin 'export const mixin = 2;')"
}
cleanup() { [[ -n "$WORK" ]] && rm -rf "$WORK"; }

run_deps() { # <dependency dir relative to app> [args]
  local dep="$1"; shift
  STATUS=0
  OUTPUT="$( cd "$WORK/app" && bash "$dep/.suede/core/deps.sh" "$@" 2>&1 )" || STATUS=$?
}

# Every `bash <(curl ...)` and `ln -s` line of the last output, as a script.
recipe() { grep -E '^ *(bash <\(curl|ln -s|\(cd )' <<<"$OUTPUT" | sed 's/^ *//'; }

the_recipe_is_complete_up_front() {
  run_deps sweater
  graph_assert_contains "$OUTPUT" 'deps: sweater needs 2 sibling' "the header counts the direct records" || return 1
  graph_assert_contains "$OUTPUT" '\[1\] dockview.sweater' "[1] is the first record" || return 1
  graph_assert_contains "$OUTPUT" 'not installed anywhere' "and it is not installed" || return 1
  graph_assert_contains "$OUTPUT" "--repo $(graph_remote "$WORK" dockview) --at $DOCKVIEW" "the install pins the recorded commit" || return 1
  graph_assert_contains "$OUTPUT" 'ln -s dockview dockview.sweater' "followed by the edge link" || return 1
  graph_assert_contains "$OUTPUT" "--at $DOCKVIEW --transitive" "and the install is marked --transitive" || return 1
  graph_assert_contains "$OUTPUT" '\[1.1\] mixin.dockview' "dockview's own record was fetched and numbered under it" || return 1
  graph_assert_contains "$OUTPUT" 'ln -s mixin mixin.dockview' "with its edge link" || return 1
  graph_assert_contains "$OUTPUT" '\[2\] mixin.sweater' "[2] is the second record" || return 1
  graph_assert_contains "$OUTPUT" 'same install as \[1.1\]' "which the recipe already installs" || return 1
  graph_assert_contains "$OUTPUT" '0 satisfied, 3 to resolve' "and the totals add up"
}

running_the_recipe_satisfies_everything() {
  run_deps sweater
  ( cd "$WORK/app" && bash <(recipe) >/dev/null 2>&1 ) || { log_failure "the recipe did not run cleanly"; return 1; }
  log_pass "the printed recipe runs as-is from the root"
  run_deps sweater
  [[ "$STATUS" == 0 ]] || { log_failure "exit $STATUS: $OUTPUT"; return 1; }
  graph_assert_contains "$OUTPUT" 'satisfied by dockview @ [0-9a-f]{7}, matches the pin' "dockview is satisfied" || return 1
  graph_assert_contains "$OUTPUT" 'everything is in place \(3 satisfied\)' "and so is everything else" || return 1
  graph_assert_absent "$WORK/app/mixin.app" "the transitive install is not declared as app's: only its edges point at it"
}

check_exits_zero_when_in_place_and_one_when_not() {
  run_deps sweater --check
  [[ "$STATUS" == 0 ]] && log_pass "--check exits 0 with everything in place" || { log_failure "exit $STATUS"; return 1; }
  rm "$WORK/app/mixin.sweater"
  run_deps sweater --check
  [[ "$STATUS" == 1 ]] && log_pass "--check exits 1 with an edge missing" || { log_failure "exit $STATUS"; return 1; }
  graph_assert_lacks "$OUTPUT" 'curl' "and prints no commands" || return 1
  graph_assert_contains "$OUTPUT" 'run without --check for the commands' "pointing at the mode that does"
}

a_missing_edge_reuses_a_clean_install() {
  run_deps sweater
  graph_assert_contains "$OUTPUT" 'found mixin at the same commit with no local changes' "mixin is already here, unchanged" || return 1
  graph_assert_contains "$OUTPUT" 'ln -s mixin mixin.sweater' "so one link finishes it" || return 1
  graph_assert_lacks "$OUTPUT" 'curl.*mixin' "and nothing is re-installed"
  ( cd "$WORK/app" && ln -s mixin mixin.sweater )
}

local_changes_turn_reuse_into_a_decision() {
  printf '// tweak\n' >> "$WORK/app/mixin/index.js"
  ( cd "$WORK/app" && bash "$INSTALL" --repo "$(graph_remote "$WORK" other)" >/dev/null 2>&1 )
  run_deps other
  graph_assert_contains "$OUTPUT" 'found mixin at the same commit, but with local changes' "the drift is named" || return 1
  graph_assert_contains "$OUTPUT" "bash mixin/.suede/core/diff --at $MIXIN" "with the diff that shows it" || return 1
  graph_assert_contains "$OUTPUT" 'ln -s mixin mixin.other' "option one: link to what you have" || return 1
  graph_assert_contains "$OUTPUT" "--at $MIXIN --name mixin-${MIXIN:0:7}" "option two: install the exact commit under another name" || return 1
  graph_assert_contains "$OUTPUT" "ln -s mixin-${MIXIN:0:7} mixin.other" "and link to that"
  ( cd "$WORK/app" && git checkout -- mixin/index.js 2>/dev/null || git -C "$WORK/app" restore --staged --worktree mixin/index.js 2>/dev/null || true )
}

a_different_commit_is_a_decision_too() {
  git -C "$WORK/app" config -f mixin/.gitrepo subrepo.commit "$MIXIN_V2"
  run_deps other
  graph_assert_contains "$OUTPUT" "found mixin from the same repository, but at ${MIXIN_V2:0:7}" "the commit difference is named" || return 1
  graph_assert_contains "$OUTPUT" 'resolve this one and re-run' "and recursion waits for the choice"
  git -C "$WORK/app" config -f mixin/.gitrepo subrepo.commit "$MIXIN"
}

a_sibling_at_another_commit_is_allowed_for_work_and_refused_for_release() {
  ( cd "$WORK/app" && ln -s mixin mixin.other )
  git -C "$WORK/app" config -f mixin/.gitrepo subrepo.commit "$MIXIN_V2"
  run_deps other
  [[ "$STATUS" == 0 ]] && log_pass "the recipe still accepts it while you work" || { log_failure "exit $STATUS: $OUTPUT"; return 1; }
  graph_assert_contains "$OUTPUT" "NOT the ${MIXIN:0:7} that mixin.other asks for" "the commit difference is spelled out" || return 1
  graph_assert_contains "$OUTPUT" "bash mixin/.suede/core/diff --at $MIXIN" "with the diff that shows it" || return 1
  graph_assert_contains "$OUTPUT" "push-release will refuse to publish it" "and says publishing will not accept it" || return 1
  graph_assert_contains "$OUTPUT" "--at $MIXIN --name mixin-${MIXIN:0:7}" "offering the exact commit beside yours" || return 1
  graph_assert_contains "$OUTPUT" "ln -s mixin-${MIXIN:0:7} mixin.other" "and the link to it" || return 1
  run_deps other --check
  [[ "$STATUS" == 1 ]] && log_pass "--check, which the publish guard runs, refuses it" || { log_failure "--check exit $STATUS: $OUTPUT"; return 1; }
  graph_assert_contains "$OUTPUT" "a release cannot ship that" "saying why"
  git -C "$WORK/app" config -f mixin/.gitrepo subrepo.commit "$MIXIN"
}

a_dangling_symlink_is_called_out() {
  rm "$WORK/app/mixin.other"; ( cd "$WORK/app" && ln -s nowhere mixin.other )
  run_deps other
  graph_assert_contains "$OUTPUT" 'mixin.other is a dangling symlink -> nowhere' "dangling is named" || return 1
  graph_assert_contains "$OUTPUT" 'rm mixin.other' "and removed first"
  rm "$WORK/app/mixin.other"
}

a_vendored_dependent_keeps_its_siblings_inside_release() {
  ( cd "$WORK/app/release" && bash "$INSTALL" --repo "$(graph_remote "$WORK" other)" --name vother >/dev/null 2>&1 )
  run_deps release/vother
  graph_assert_lacks "$OUTPUT" 'ln -s \.\./mixin' "the mixin outside release/ is not offered" || return 1
  graph_assert_contains "$OUTPUT" '\(cd release && bash <\(curl' "the install is placed inside release/" || return 1
  graph_assert_contains "$OUTPUT" 'ln -s mixin release/mixin.other' "and so is the link"
}

in_runs_against_another_dependency() {
  STATUS=0
  OUTPUT="$( cd "$WORK" && bash "$WORK/app/sweater/.suede/core/deps.sh" --in "$WORK/app/dockview" 2>&1 )" || STATUS=$?
  graph_assert_contains "$OUTPUT" 'deps: dockview needs 1 sibling' "--in points it at dockview" || return 1
  STATUS=0
  OUTPUT="$( cd "$WORK/app" && bash release/.suede/core/deps.sh --in release 2>&1 )" || STATUS=$?
  graph_assert_contains "$OUTPUT" 'deps: release needs' "--in release reads this repository's own records"
}

the_look_ahead_falls_back_to_https() {
  # A record naming the SSH spelling of a dependency only reachable over HTTPS:
  # deps.sh still reads that dependency's own records.
  graph_make_project "$WORK" app2 --dependency
  graph_make_dep "$WORK" top "dockview.top=git@example.test:owner/dockview.git@$DOCKVIEW" >/dev/null
  ( cd "$WORK/app2" && bash "$INSTALL" --repo "$(graph_remote "$WORK" top)" >/dev/null 2>&1 )
  graph_https_only "$(graph_remote "$WORK" dockview)" owner/dockview
  STATUS=0
  OUTPUT="$( cd "$WORK/app2" && bash top/.suede/core/deps.sh 2>&1 )" || STATUS=$?
  graph_forget_https
  graph_assert_contains "$OUTPUT" '\[1.1\] mixin.dockview' "dockview's records were fetched over HTTPS"
}

https_skips_ssh_and_is_passed_on_to_the_recipe() {
  # app2 and top come from the previous test: top's record names dockview by
  # its SSH spelling, and dockview is only reachable over HTTPS.
  https_only_remote "$(graph_remote "$WORK" dockview)" owner/dockview
  ssh_spy_start
  STATUS=0
  OUTPUT="$( cd "$WORK/app2" && bash top/.suede/core/deps.sh --https 2>&1 )" || STATUS=$?
  assert_no_ssh "--https makes no SSH attempt during the look-ahead" || { ssh_spy_stop; forget_https_only_remote; return 1; }
  ssh_spy_stop; forget_https_only_remote
  graph_assert_contains "$OUTPUT" '\[1.1\] mixin.dockview' "and still reads dockview's records" || return 1
  graph_assert_contains "$OUTPUT" -- '--transitive --https' "every install it prints carries --https"
}

run_test_suite --setup setup --cleanup cleanup \
  the_recipe_is_complete_up_front \
  running_the_recipe_satisfies_everything \
  check_exits_zero_when_in_place_and_one_when_not \
  a_missing_edge_reuses_a_clean_install \
  local_changes_turn_reuse_into_a_decision \
  a_different_commit_is_a_decision_too \
  a_sibling_at_another_commit_is_allowed_for_work_and_refused_for_release \
  a_dangling_symlink_is_called_out \
  a_vendored_dependent_keeps_its_siblings_inside_release \
  in_runs_against_another_dependency \
  the_look_ahead_falls_back_to_https \
  https_skips_ssh_and_is_passed_on_to_the_recipe
