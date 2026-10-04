#!/usr/bin/env bash
# extract.sh, list.sh and diff.sh: the maintainer's read of the tree.
#
# All three apply one rule - a root symlink named <name><sep><repo> that resolves
# to an install outside release/ is a release dependency - so they are tested
# together, against the same tree.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$TESTS_DIR/../core" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/../../.." && pwd)"
HARNESS="$ROOT_DIR/.tests/harness"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"
source "$HARNESS/with-suede-graph.sh"
source "$HARNESS/ssh-spy.sh"

INSTALL="$ROOT_DIR/scripts/install/release.sh"
WORK=""; WIDGET=""; OUTPUT=""; STATUS=0

setup() {
  WORK="$(mktemp -d)"
  WIDGET="$(graph_make_dep "$WORK" widget)"
  graph_make_dep "$WORK" gizmo >/dev/null
  graph_make_dep "$WORK" tool >/dev/null
  graph_make_project "$WORK" lib --dependency
  ( cd "$WORK/lib"
    bash "$INSTALL" --repo "$(graph_remote "$WORK" widget)" >/dev/null 2>&1
    bash "$INSTALL" --repo "$(graph_remote "$WORK" gizmo)" --sep __ >/dev/null 2>&1
    bash "$INSTALL" --repo "$(graph_remote "$WORK" tool)" --dev >/dev/null 2>&1
    ( cd release && bash "$INSTALL" --repo "$(graph_remote "$WORK" tool)" --name vtool >/dev/null 2>&1 )
    # What older versions generated, and a record for an entry that is gone.
    mkdir -p release/.suede/.dependencies
    printf '{}\n' > release/.suede/.dependencies/package.json
    printf '.\n' > release/.suede/.dependencies/separator
    printf '[subrepo]\n\tremote = x\n\tcommit = y\n' > release/.suede/.dependencies/gone.lib.gitrepo
    git add -A; git commit --quiet -m "install" )
}
cleanup() { [[ -n "$WORK" ]] && rm -rf "$WORK"; }

run() { # <script> [args]
  local script="$1"; shift
  STATUS=0
  OUTPUT="$( cd "$WORK/lib" && bash "$CORE_DIR/$script" "$@" 2>&1 )" || STATUS=$?
}

extract_writes_one_record_per_declared_entry() {
  run extract.sh
  [[ "$STATUS" == 0 ]] || { log_failure "extract failed: $OUTPUT"; return 1; }
  local records="$WORK/lib/release/.suede/.dependencies"
  [[ -f "$records/widget.lib.gitrepo" ]] && log_pass "widget.lib is recorded" || return 1
  [[ -f "$records/gizmo__lib.gitrepo" ]] && log_pass "gizmo__lib is recorded (the __ separator counts too)" || return 1
  [[ ! -f "$records/tool.gitrepo" && ! -f "$records/tool.lib.gitrepo" ]] && log_pass "the --dev install is not" || return 1
  [[ ! -f "$records/vtool.gitrepo" ]] && log_pass "nor is the vendored one" || return 1
  [[ "$(git config -f "$records/widget.lib.gitrepo" subrepo.commit)" == "$WIDGET" ]] \
    && log_pass "the record carries the pinned commit" || return 1
  git config -f "$records/widget.lib.gitrepo" subrepo.parent >/dev/null 2>&1 \
    && { log_failure "the record carries parent, which means nothing downstream"; return 1; }
  log_pass "and no local bookkeeping"
}

extract_removes_what_it_did_not_write() {
  local records="$WORK/lib/release/.suede/.dependencies"
  printf '{}\n' > "$records/package.json"
  printf '.\n' > "$records/separator"
  printf '[subrepo]\n\tremote = x\n\tcommit = y\n' > "$records/gone.lib.gitrepo"
  run extract.sh
  graph_assert_absent "$records/package.json" "the generated package.json is gone" || return 1
  graph_assert_absent "$records/separator" "so is the separator file" || return 1
  graph_assert_absent "$records/gone.lib.gitrepo" "and the stale record" || return 1
  graph_assert_contains "$OUTPUT" 'removed .*package.json \(no longer generated\)' "each removal is reported"
}

records_publish_the_https_spelling() {
  git -C "$WORK/lib" config -f widget/.gitrepo subrepo.remote "git@github.com:owner/widget.git"
  run extract.sh
  [[ "$(git config -f "$WORK/lib/release/.suede/.dependencies/widget.lib.gitrepo" subrepo.remote)" == "https://github.com/owner/widget" ]] \
    && log_pass "an SSH remote is published as HTTPS" || { log_failure "got $(git config -f "$WORK/lib/release/.suede/.dependencies/widget.lib.gitrepo" subrepo.remote)"; return 1; }
  git -C "$WORK/lib" config -f widget/.gitrepo subrepo.remote "$(graph_remote "$WORK" widget)"
}

a_dangling_declaration_is_reported_and_skipped() {
  ( cd "$WORK/lib" && ln -s nowhere ghost.lib )
  run extract.sh
  graph_assert_contains "$OUTPUT" 'ghost.lib: dangling' "the dangling entry is named" || return 1
  graph_assert_absent "$WORK/lib/release/.suede/.dependencies/ghost.lib.gitrepo" "and not recorded"
  rm "$WORK/lib/ghost.lib"
}

a_real_folder_never_declares() {
  # Named exactly like a declaration, but a folder: only a symlink declares.
  ( cd "$WORK/lib" && cp -R widget fake.lib )
  run extract.sh
  graph_assert_absent "$WORK/lib/release/.suede/.dependencies/fake.lib.gitrepo" "a folder named fake.lib is not a declaration"
  rm -rf "$WORK/lib/fake.lib"
}

a_transitive_install_is_listed_and_compared() {
  # nest needs egg. lib installs nest (declared) and runs the recipe, which
  # installs egg --transitive: no declaration, only the edge egg.nest.
  local egg
  egg="$(graph_make_dep "$WORK" egg)"
  graph_make_dep "$WORK" nest "egg.nest=$(graph_remote "$WORK" egg)@$egg" >/dev/null
  ( cd "$WORK/lib"
    SUEDE_INSTALL_URL="file://$INSTALL" bash "$INSTALL" --repo "$(graph_remote "$WORK" nest)" > "$WORK/nest.txt" 2>&1
    SUEDE_INSTALL_URL="file://$INSTALL" bash <(grep -E '^ *(bash <\(curl|ln -s)' "$WORK/nest.txt" | sed 's/^ *//') >/dev/null 2>&1
    git add -A && git commit --quiet -m "install nest" )
  graph_assert_absent "$WORK/lib/egg.lib" "precondition: egg is not declared" || return 1

  run list.sh
  graph_assert_contains "$OUTPUT" '^transitive +egg.nest +egg ' "list.sh calls egg transitive, naming the edge that reaches it" || return 1
  run extract.sh
  graph_assert_absent "$WORK/lib/release/.suede/.dependencies/egg.lib.gitrepo" "extract.sh publishes no record for it" || return 1

  printf '// local\n' >> "$WORK/lib/egg/index.js"
  run diff.sh
  [[ "$STATUS" == 1 ]] && log_pass "an edit to the undeclared egg fails diff.sh" || { log_failure "exit $STATUS: $OUTPUT"; return 1; }
  graph_assert_contains "$OUTPUT" 'egg.nest \(egg, transitive\) has local changes' "naming it as transitive"
  git -C "$WORK/lib" checkout -- egg/index.js
}

list_classifies_every_install() {
  run list.sh
  graph_assert_contains "$OUTPUT" '^release +widget.lib +widget ' "widget is a release dependency" || return 1
  graph_assert_contains "$OUTPUT" '^release +gizmo__lib +gizmo ' "gizmo too, through __" || return 1
  graph_assert_contains "$OUTPUT" '^development +- +tool ' "tool is development" || return 1
  graph_assert_contains "$OUTPUT" '^vendored +- +release/vtool ' "vtool is vendored" || return 1
  graph_assert_lacks "$OUTPUT" '\.suede/core' "and suede's own machinery is left out"
}

diff_passes_a_pristine_tree_and_fails_a_modified_one() {
  run diff.sh
  [[ "$STATUS" == 0 ]] && log_pass "a pristine tree passes" || { log_failure "exit $STATUS: $OUTPUT"; return 1; }
  # widget, gizmo and nest are declared, egg is reached through nest's edge,
  # and tool is development: all five by default, the first four when shipped.
  graph_assert_contains "$OUTPUT" '5 checked' "by default every installed dependency is checked, development included" || return 1
  run diff.sh --shipped-only
  graph_assert_contains "$OUTPUT" '4 checked' "--shipped-only checks the four that ship" || return 1
  printf '// local\n' >> "$WORK/lib/widget/index.js"
  run diff.sh
  [[ "$STATUS" == 1 ]] && log_pass "a modified one fails with 1" || { log_failure "exit $STATUS: $OUTPUT"; return 1; }
  graph_assert_contains "$OUTPUT" 'widget.lib \(widget, release\) has local changes' "naming the entry and its kind" || return 1
  graph_assert_contains "$OUTPUT" 'index.js' "and the file" || return 1
  graph_assert_contains "$OUTPUT" 'The publish guard refuses' "saying a publish would be refused"
  git -C "$WORK/lib" checkout -- widget/index.js
}

development_changes_are_reported_but_never_block_a_publish() {
  printf '// local\n' >> "$WORK/lib/tool/index.js"
  run diff.sh
  [[ "$STATUS" == 1 ]] && log_pass "by default a development dependency's changes are reported, exit 1" || { log_failure "exit $STATUS: $OUTPUT"; return 1; }
  graph_assert_contains "$OUTPUT" 'tool \(development\) has local changes' "named as development" || return 1
  graph_assert_contains "$OUTPUT" 'do not block a publish' "with a note that they do not block a publish" || return 1
  graph_assert_lacks "$OUTPUT" 'The publish guard refuses' "and no claim that they do" || return 1
  run diff.sh --shipped-only
  [[ "$STATUS" == 0 ]] && log_pass "--shipped-only, what the guard runs, ignores them" || { log_failure "exit $STATUS: $OUTPUT"; return 1; }
  git -C "$WORK/lib" checkout -- tool/index.js
}

vendored_dependencies_are_never_checked() {
  printf '// local\n' >> "$WORK/lib/release/vtool/index.js"
  run diff.sh
  [[ "$STATUS" == 0 ]] && log_pass "a vendored dependency's changes are expected, not reported" || { log_failure "exit $STATUS: $OUTPUT"; return 1; }
  git -C "$WORK/lib" checkout -- release/vtool/index.js
}

being_behind_is_reported_by_default_and_never_fails() {
  local widget_tip tool_tip
  widget_tip="$(graph_advance_dep "$WORK" widget 'export const widget = 9;')"
  tool_tip="$(graph_advance_dep "$WORK" tool 'export const tool = 9;')"
  run diff.sh
  [[ "$STATUS" == 0 ]] && log_pass "being behind is not an exit code" || { log_failure "exit $STATUS: $OUTPUT"; return 1; }
  graph_assert_contains "$OUTPUT" "widget.lib \(widget, release\) is behind: pinned [0-9a-f]{7}, its branch is at ${widget_tip:0:7}" "a release dependency behind its branch is named" || return 1
  graph_assert_contains "$OUTPUT" "tool \(development\) is behind: pinned [0-9a-f]{7}, its branch is at ${tool_tip:0:7}" "so is a development one" || return 1
  graph_assert_contains "$OUTPUT" 'diff --in widget --sync' "with the command that shows what a sync brings" || return 1
  graph_assert_contains "$OUTPUT" '2 behind' "and counted" || return 1
  run diff.sh --shipped-only
  graph_assert_lacks "$OUTPUT" 'behind' "--shipped-only does not look"
}

https_reaches_every_remote_without_ssh() {
  # widget recorded over SSH, reachable only over HTTPS: diff.sh compares it
  # (through the shipped diff) and asks for its tip (ls-remote) - both must
  # honour --https.
  git -C "$WORK/lib" config -f widget/.gitrepo subrepo.remote "git@example.test:owner/widget.git"
  https_only_remote "$(graph_remote "$WORK" widget)" owner/widget
  ssh_spy_start
  run diff.sh --https
  assert_no_ssh "diff.sh --https makes no SSH attempt" || { ssh_spy_stop; forget_https_only_remote; return 1; }
  graph_assert_lacks "$OUTPUT" 'widget.*could not' "and still compares widget and reads its tip" || { ssh_spy_stop; forget_https_only_remote; return 1; }
  : > "$SSH_SPY_DIR/calls"
  run diff.sh
  assert_ssh_tried "without it, SSH is tried first"
  ssh_spy_stop; forget_https_only_remote
  git -C "$WORK/lib" config -f widget/.gitrepo subrepo.remote "$(graph_remote "$WORK" widget)"
}

run_test_suite --setup setup --cleanup cleanup \
  extract_writes_one_record_per_declared_entry \
  extract_removes_what_it_did_not_write \
  records_publish_the_https_spelling \
  a_dangling_declaration_is_reported_and_skipped \
  a_real_folder_never_declares \
  a_transitive_install_is_listed_and_compared \
  list_classifies_every_install \
  diff_passes_a_pristine_tree_and_fails_a_modified_one \
  development_changes_are_reported_but_never_block_a_publish \
  vendored_dependencies_are_never_checked \
  being_behind_is_reported_by_default_and_never_fails \
  https_reaches_every_remote_without_ssh
