#!/usr/bin/env bash
# The installer, against real local repositories.
#
# What is worth pinning: the tree and .gitrepo it writes, and - the whole of
# what makes an install mean something - when it declares (the <name><sep><repo>
# symlink) and when it does not. Runs on bash 3.2, because consumers do.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/../.." && pwd)"
HARNESS="$ROOT_DIR/.tests/harness"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"
source "$HARNESS/with-suede-graph.sh"
source "$HARNESS/ssh-spy.sh"

INSTALL="$ROOT_DIR/scripts/install/release.sh"
WORK=""; WIDGET=""; WIDGET_V2=""; OUTPUT=""; STATUS=0

setup() {
  WORK="$(mktemp -d)"
  WIDGET="$(graph_make_dep "$WORK" widget)"
  WIDGET_V2="$(graph_advance_dep "$WORK" widget 'export const widget = 2;')"
  graph_make_dep "$WORK" gadget "widget.gadget=$(graph_remote "$WORK" widget)@$WIDGET" >/dev/null
  graph_make_project "$WORK" lib --dependency
  graph_make_project "$WORK" app
}
cleanup() { [[ -n "$WORK" ]] && rm -rf "$WORK"; }

install_in() { # <dir> <args...>
  local dir="$1"; shift
  STATUS=0
  OUTPUT="$( cd "$dir" && bash "$INSTALL" "$@" 2>&1 )" || STATUS=$?
}

installs_the_release_tree_and_a_gitrepo() {
  install_in "$WORK/lib" --repo "$(graph_remote "$WORK" widget)"
  [[ "$STATUS" == 0 ]] || { log_failure "install failed: $OUTPUT"; return 1; }
  local dep="$WORK/lib/widget"
  grep -q 'widget = 2' "$dep/index.js" && log_pass "the release tip's files are in place" \
    || { log_failure "index.js is not the tip's"; return 1; }
  [[ "$(graph_field "$dep" commit)" == "$WIDGET_V2" ]] && log_pass ".gitrepo pins the tip" \
    || { log_failure ".gitrepo commit is $(graph_field "$dep" commit)"; return 1; }
  [[ "$(graph_field "$dep" branch)" == "release" ]] && log_pass ".gitrepo names the branch" || return 1
  [[ "$(graph_field "$dep" parent)" == "$(git -C "$WORK/lib" rev-parse HEAD)" ]] \
    && log_pass ".gitrepo's parent is this repo's HEAD, for a later git subrepo pull" || return 1
  [[ ! -e "$dep/.git" ]] && log_pass "no .git came along" || return 1
  git -C "$WORK/lib" diff --cached --name-only | grep -q '^widget/index.js$' \
    && log_pass "staged, not committed" || { log_failure "not staged"; return 1; }
  [[ -z "$(git -C "$WORK/lib" log -1 --format=%s | grep widget || true)" ]] \
    && log_pass "nothing was committed" || return 1
  # Each test runs in its own subshell, so what the install printed is checked
  # here, where it was run.
  graph_assert_link "$WORK/lib/widget.lib" widget "widget.lib -> widget declares it a release dependency" || return 1
  git -C "$WORK/lib" diff --cached --name-only | grep -q '^widget.lib$' \
    && log_pass "the symlink is staged too" || { log_failure "symlink not staged"; return 1; }
  graph_assert_contains "$OUTPUT" 'declared as a release dependency of lib' "and the output says so" || return 1
  graph_assert_contains "$OUTPUT" 'deps: widget needs 0 sibling' "deps.sh ran and found nothing to do"
}

runs_deps_after_installing() {
  install_in "$WORK/lib" --repo "$(graph_remote "$WORK" gadget)"
  graph_assert_contains "$OUTPUT" '\[1\] widget.gadget' "a dependency with edges gets its recipe printed" || return 1
  graph_assert_contains "$OUTPUT" 'ln -s widget widget.gadget' "which reuses the widget already installed"
}

refuses_a_taken_name_and_offers_the_naming_flags() {
  install_in "$WORK/lib" --repo "$(graph_remote "$WORK" widget)"
  [[ "$STATUS" != 0 ]] && log_pass "a second install under the same name is refused" || return 1
  graph_assert_contains "$OUTPUT" -- '--name <folder>, --prefix <text> or --suffix <text>' "and names the way past it" || return 1
  install_in "$WORK/lib" --repo "$(graph_remote "$WORK" widget)" --at "$WIDGET" --suffix "-$WIDGET"
  [[ "$STATUS" == 0 ]] || { log_failure "--suffix install failed: $OUTPUT"; return 1; }
  [[ -d "$WORK/lib/widget-$WIDGET" ]] && log_pass "--suffix names the folder" || return 1
  graph_assert_link "$WORK/lib/widget-$WIDGET.lib" "widget-$WIDGET" "and the declaration follows the name"
}

at_installs_a_specific_commit() {
  [[ -d "$WORK/lib/widget-$WIDGET" ]] || install_in "$WORK/lib" --repo "$(graph_remote "$WORK" widget)" --at "$WIDGET" --suffix "-$WIDGET"
  grep -q 'widget = 1' "$WORK/lib/widget-$WIDGET/index.js" && log_pass "--at installed the older commit" || return 1
  [[ "$(graph_field "$WORK/lib/widget-$WIDGET" commit)" == "$WIDGET" ]] && log_pass "and pinned it" || return 1
}

sep_changes_the_declaring_name() {
  install_in "$WORK/lib" --repo "$(graph_remote "$WORK" widget)" --name w3 --sep __
  graph_assert_link "$WORK/lib/w3__lib" w3 "--sep __ gives w3__lib"
}

dev_installs_without_declaring() {
  install_in "$WORK/lib" --repo "$(graph_remote "$WORK" widget)" --name w4 --dev
  [[ -d "$WORK/lib/w4" ]] && log_pass "--dev installs" || return 1
  graph_assert_absent "$WORK/lib/w4.lib" "and creates no symlink"
  graph_assert_contains "$OUTPUT" 'not declared \(--dev\)' "saying so"
}

transitive_installs_without_declaring_and_says_why() {
  install_in "$WORK/lib" --repo "$(graph_remote "$WORK" widget)" --name w7 --transitive
  [[ "$STATUS" == 0 && -d "$WORK/lib/w7" ]] && log_pass "--transitive installs" || { log_failure "$OUTPUT"; return 1; }
  graph_assert_absent "$WORK/lib/w7.lib" "and creates no declaration" || return 1
  graph_assert_contains "$OUTPUT" 'not declared \(--transitive\)' "it says why" || return 1
  graph_assert_contains "$OUTPUT" 'ln -s w7 w7.lib' "and how to declare it if your own code imports it" || return 1
  mkdir -p "$WORK/lib/nested"
  install_in "$WORK/lib/nested" --repo "$(graph_remote "$WORK" widget)" --transitive
  [[ "$STATUS" == 0 ]] && log_pass "like --dev, it may install away from the root" || { log_failure "$OUTPUT"; return 1; }
  install_in "$WORK/lib" --repo "$(graph_remote "$WORK" widget)" --name w8 --dev --transitive
  [[ "$STATUS" != 0 ]] && log_pass "--dev with --transitive is refused" || return 1
}

inside_release_installs_vendored() {
  install_in "$WORK/lib/release" --repo "$(graph_remote "$WORK" widget)"
  [[ "$STATUS" == 0 ]] || { log_failure "vendored install failed: $OUTPUT"; return 1; }
  [[ -d "$WORK/lib/release/widget" ]] && log_pass "inside release/ the folder lands there" || return 1
  graph_assert_absent "$WORK/lib/release/widget.lib" "and nothing is linked"
  graph_assert_contains "$OUTPUT" 'vendored source' "the output calls it vendored"
}

outside_the_root_a_release_install_is_refused() {
  mkdir -p "$WORK/lib/deps"
  install_in "$WORK/lib/deps" --repo "$(graph_remote "$WORK" widget)"
  [[ "$STATUS" != 0 ]] && log_pass "a release install away from the root is refused" || return 1
  graph_assert_contains "$OUTPUT" 'has to sit beside release/' "with the reason" || return 1
  install_in "$WORK/lib/deps" --repo "$(graph_remote "$WORK" widget)" --dev
  [[ "$STATUS" == 0 && -d "$WORK/lib/deps/widget" ]] && log_pass "--dev may install anywhere" || return 1
}

a_plain_consumer_declares_nothing() {
  install_in "$WORK/app" --repo "$(graph_remote "$WORK" widget)"
  [[ "$STATUS" == 0 && -d "$WORK/app/widget" ]] || { log_failure "install failed: $OUTPUT"; return 1; }
  graph_assert_absent "$WORK/app/widget.app" "no release/.gitrepo, no declaring symlink"
  graph_assert_contains "$OUTPUT" 'not a suede dependency' "and the output explains why"
}

the_repo_name_comes_from_origin() {
  # The folder is not called what origin calls it: origin wins.
  mv "$WORK/lib" "$WORK/renamed-checkout"
  install_in "$WORK/renamed-checkout" --repo "$(graph_remote "$WORK" widget)" --name w5
  graph_assert_link "$WORK/renamed-checkout/w5.lib" w5 "the repo's name is origin's, not the folder's"
  mv "$WORK/renamed-checkout" "$WORK/lib"
}

a_suede_prefix_is_not_repeated_in_the_symlink() {
  graph_make_dep "$WORK" suede.widget >/dev/null
  graph_make_dep "$WORK" suede__pywidget >/dev/null
  graph_make_project "$WORK" suede.app --dependency
  install_in "$WORK/suede.app" --repo "$(graph_remote "$WORK" suede.widget)"
  [[ -d "$WORK/suede.app/suede.widget" ]] && log_pass "the folder keeps its full name" || { log_failure "$OUTPUT"; return 1; }
  graph_assert_link "$WORK/suede.app/suede.widget.app" suede.widget "suede.app + suede.widget declares suede.widget.app: what it is, then who needs it" || return 1
  graph_assert_absent "$WORK/suede.app/suede.widget.suede.app" "not suede.widget.suede.app" || return 1
  install_in "$WORK/suede.app" --repo "$(graph_remote "$WORK" suede__pywidget)" --sep __
  graph_assert_link "$WORK/suede.app/suede__pywidget__app" suede__pywidget "a suede__ dependency drops suede.app's prefix too"
}

a_suede__repository_defaults_to_the___separator() {
  # The Python convention: suede__wsfs needs suede__sqlmodel_utils.
  graph_make_dep "$WORK" suede__sqlmodel_utils >/dev/null
  graph_make_project "$WORK" suede__wsfs --dependency
  install_in "$WORK/suede__wsfs" --repo "$(graph_remote "$WORK" suede__sqlmodel_utils)"
  graph_assert_link "$WORK/suede__wsfs/suede__sqlmodel_utils__wsfs" suede__sqlmodel_utils \
    "suede__wsfs + suede__sqlmodel_utils declares suede__sqlmodel_utils__wsfs, with no --sep"
}

an_unprefixed_repository_keeps_the_dependency_prefix() {
  graph_make_dep "$WORK" suede.gizmo >/dev/null
  install_in "$WORK/lib" --repo "$(graph_remote "$WORK" suede.gizmo)"
  graph_assert_link "$WORK/lib/suede.gizmo.lib" suede.gizmo "lib + suede.gizmo still declares suede.gizmo.lib"
}

by_default_ssh_is_tried_first_then_https() {
  graph_make_project "$WORK" app3
  https_only_remote "$(graph_remote "$WORK" widget)" owner/widget
  ssh_spy_start
  install_in "$WORK/app3" --repo git@example.test:owner/widget.git --name s1
  local calls; calls="$(ssh_spy_calls)"
  ssh_spy_stop; forget_https_only_remote
  [[ "$STATUS" == 0 && -d "$WORK/app3/s1" ]] && log_pass "installed through the HTTPS fallback" || { log_failure "$OUTPUT"; return 1; }
  [[ "$calls" -gt 0 ]] && log_pass "after trying SSH first" || { log_failure "ssh was never tried"; return 1; }
}

https_skips_ssh_and_reaches_the_recipe() {
  graph_make_project "$WORK" app4
  https_only_remote "$(graph_remote "$WORK" widget)" owner/widget
  ssh_spy_start
  install_in "$WORK/app4" --repo git@example.test:owner/widget.git --name s2 --https
  assert_no_ssh "--https makes no SSH attempt" || { ssh_spy_stop; forget_https_only_remote; return 1; }
  ssh_spy_stop; forget_https_only_remote
  [[ "$STATUS" == 0 && -d "$WORK/app4/s2" ]] && log_pass "and installs over HTTPS" || { log_failure "$OUTPUT"; return 1; }
  [[ "$(graph_field "$WORK/app4/s2" remote)" == "git@example.test:owner/widget.git" ]] \
    && log_pass "the .gitrepo still records the SSH remote, for upstream" \
    || { log_failure "recorded $(graph_field "$WORK/app4/s2" remote)"; return 1; }
  # gadget needs widget, which app4 does not have under that name: the recipe
  # deps.sh prints must carry --https too.
  install_in "$WORK/app4" --repo "$(graph_remote "$WORK" gadget)" --https
  graph_assert_contains "$OUTPUT" -- '--transitive --https' "the recipe it prints carries --https"
}

a_missing_branch_fails_clearly() {
  install_in "$WORK/app" --repo "$(graph_remote "$WORK" widget)" --branch nope --name w6
  [[ "$STATUS" != 0 ]] && log_pass "an absent branch fails" || return 1
  graph_assert_contains "$OUTPUT" "could not find branch 'nope'" "and says which"
}

run_test_suite --setup setup --cleanup cleanup \
  installs_the_release_tree_and_a_gitrepo \
  runs_deps_after_installing \
  refuses_a_taken_name_and_offers_the_naming_flags \
  at_installs_a_specific_commit \
  sep_changes_the_declaring_name \
  dev_installs_without_declaring \
  transitive_installs_without_declaring_and_says_why \
  inside_release_installs_vendored \
  outside_the_root_a_release_install_is_refused \
  a_plain_consumer_declares_nothing \
  the_repo_name_comes_from_origin \
  a_suede_prefix_is_not_repeated_in_the_symlink \
  a_suede__repository_defaults_to_the___separator \
  an_unprefixed_repository_keeps_the_dependency_prefix \
  by_default_ssh_is_tried_first_then_https \
  https_skips_ssh_and_reaches_the_recipe \
  a_missing_branch_fails_clearly
