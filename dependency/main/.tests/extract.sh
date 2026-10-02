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
  [[ "$STATUS" == 0 ]] && log_pass "pristine release dependencies pass" || { log_failure "exit $STATUS: $OUTPUT"; return 1; }
  graph_assert_contains "$OUTPUT" '2 checked' "both release dependencies were compared" || return 1
  printf '// local\n' >> "$WORK/lib/widget/index.js"
  run diff.sh
  [[ "$STATUS" == 1 ]] && log_pass "a modified one fails with 1" || { log_failure "exit $STATUS: $OUTPUT"; return 1; }
  graph_assert_contains "$OUTPUT" 'widget.lib \(widget\) has local modifications' "naming the entry" || return 1
  graph_assert_contains "$OUTPUT" 'index.js' "and the file"
  git -C "$WORK/lib" checkout -- widget/index.js
}

diff_leaves_development_and_vendored_alone() {
  printf '// local\n' >> "$WORK/lib/tool/index.js"
  printf '// local\n' >> "$WORK/lib/release/vtool/index.js"
  run diff.sh
  [[ "$STATUS" == 0 ]] && log_pass "changes to a dev or vendored dependency do not fail diff" || { log_failure "exit $STATUS: $OUTPUT"; return 1; }
}

run_test_suite --setup setup --cleanup cleanup \
  extract_writes_one_record_per_declared_entry \
  extract_removes_what_it_did_not_write \
  records_publish_the_https_spelling \
  a_dangling_declaration_is_reported_and_skipped \
  a_real_folder_never_declares \
  list_classifies_every_install \
  diff_passes_a_pristine_tree_and_fails_a_modified_one \
  diff_leaves_development_and_vendored_alone
