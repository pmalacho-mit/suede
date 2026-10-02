#!/usr/bin/env bash
# The publish guard, against real local repositories.
#
# What is worth pinning here is the refusal: a release dependency ships as a
# pointer, so a diverged dependency or a declared sibling that is not there
# must stop the publish rather than send a lie out to consumers. Those cases
# stop before the remote is touched, so they need no git-subrepo.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$TESTS_DIR/../core" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/../../.." && pwd)"
HARNESS="$ROOT_DIR/.tests/harness"
source "$HARNESS/runner.sh"; source "$HARNESS/color-logging.sh"
source "$HARNESS/with-suede-graph.sh"

readonly PUSH_RELEASE="$CORE_DIR/push-release.sh"
INSTALL="$ROOT_DIR/scripts/install/release.sh"
# Recipes printed by deps.sh run this installer, not the hosted one.
export SUEDE_INSTALL_URL="file://$INSTALL"
WORK=""; OUT=""

# widget <- gadget, and a library declaring gadget (and so, after the recipe,
# widget) as release dependencies of its own.
setup() {
  WORK="$(mktemp -d)"
  local widget
  widget="$(graph_make_dep "$WORK" widget)"
  graph_make_dep "$WORK" gadget "widget.gadget=$(graph_remote "$WORK" widget)@$widget" >/dev/null
  graph_make_project "$WORK" library --dependency
  ( cd "$WORK/library"
    bash "$INSTALL" --repo "$(graph_remote "$WORK" gadget)" >/dev/null 2>&1
    bash "$INSTALL" --repo "$(graph_remote "$WORK" widget)" >/dev/null 2>&1
    ln -s widget widget.gadget
    git add -A; git commit --quiet -m "install gadget" )
  OUT="$WORK/out.txt"
}
cleanup() { [[ -n "$WORK" ]] && rm -rf "$WORK"; }

# DRY_RUN stops after the guard, which is everything these cases are about.
guard() { ( cd "$WORK/library" && DRY_RUN=1 bash "$PUSH_RELEASE" ) > "$OUT" 2>&1; }

assert_reports() {
  local needle="$1" description="$2"
  if grep -q -- "$needle" "$OUT"; then log_pass "$description"; else log_failure "$description"; cat "$OUT" >&2; return 1; fi
}

an_honest_tree_passes_the_guard() {
  guard || { log_failure "guard failed on a clean tree"; cat "$OUT" >&2; return 1; }
  log_pass "guard passed on a clean tree"
}

the_records_are_refreshed_and_committed() {
  [[ -f "$WORK/library/release/.suede/.dependencies/gadget.library.gitrepo" ]] \
    && log_pass "extract recorded gadget" || { log_failure "no gadget record"; return 1; }
  [[ -f "$WORK/library/release/.suede/.dependencies/widget.library.gitrepo" ]] \
    && log_pass "and widget, which the recipe declared" || return 1
  git -C "$WORK/library" log -1 --format=%s | grep -q 'update dependency records' \
    && log_pass "and committed them" || { log_failure "no commit"; return 1; }
  git -C "$WORK/library" diff --quiet && log_pass "leaving a clean tree" || return 1
}

a_diverged_release_dependency_refuses_to_publish() {
  printf 'local edit\n' >> "$WORK/library/widget/index.js"
  if guard; then log_failure "a diverged dependency stops the publish"; cat "$OUT" >&2; return 1; fi
  log_pass "a diverged dependency stops the publish"
  assert_reports "diverged from its pin" "the report names divergence as the reason" || return 1
  assert_reports "release branch is unchanged" "and says the release branch was left alone"
  git -C "$WORK/library" checkout -- widget/index.js
}

a_missing_sibling_refuses_to_publish() {
  rm "$WORK/library/widget.gadget"
  if guard; then log_failure "a missing sibling stops the publish"; cat "$OUT" >&2; return 1; fi
  log_pass "a missing sibling stops the publish"
  assert_reports "not in place" "the report names the missing sibling as the reason" || return 1
  assert_reports "widget.gadget" "and which one"
  ( cd "$WORK/library" && ln -s widget widget.gadget )
}

a_stale_release_core_is_named_rather_than_worked_around() {
  rm "$WORK/library/release/.suede/core/deps.sh"
  if guard; then log_failure "a core without deps.sh should fail the publish"; return 1; fi
  assert_reports "sync.sh" "the fix (sync the vendored core) is named"
  cp "$ROOT_DIR/dependency/release/core/deps.sh" "$WORK/library/release/.suede/core/deps.sh"
}

an_ssh_remote_is_compared_over_https_when_ssh_is_unavailable() {
  # The CI failure this guards against: the installer records the SSH spelling,
  # a runner has no key, and the guard must still be able to compare.
  graph_https_only "$(graph_remote "$WORK" widget)" owner/widget
  git -C "$WORK/library" config -f widget/.gitrepo subrepo.remote "git@example.test:owner/widget.git"
  git -C "$WORK/library" commit --quiet -am "record widget over ssh"
  guard || true
  graph_forget_https
  # Only the comparison is under test. gadget's record names widget by its
  # local path, so deps.sh rightly calls the re-recorded widget a different
  # repository; on GitHub both spellings normalise to one.
  if grep -qE 'could not compare|diverged from its pin' "$OUT"; then
    log_failure "the guard could not compare widget over https"; cat "$OUT" >&2; return 1
  fi
  log_pass "an SSH-recorded release dependency is compared over HTTPS"
}

suede_prefixed_names_are_detected_and_resolve_downstream() {
  # suede.repoC <- suede.repoB <- suede.repoA, all prefixed, as published repos
  # are named now. The installer shortens each declaration (suede.repoB.repoA);
  # the guard has to find those, and a consumer has to resolve the records.
  local c b out
  c="$(graph_make_dep "$WORK" suede.repoC)"
  graph_make_project "$WORK" suede.repoB --dependency
  ( cd "$WORK/suede.repoB"
    bash "$INSTALL" --repo "$(graph_remote "$WORK" suede.repoC)" >/dev/null 2>&1
    bash .suede/core/extract.sh >/dev/null 2>&1
    git add -A; git commit --quiet -m "install suede.repoC"
    # Publish suede.repoB's release/ as its release branch: what CI's
    # `git subrepo push release` puts there is exactly that folder's contents.
    local out_dir="$WORK/suede.repoB-release"
    mkdir -p "$out_dir" && cp -R release/. "$out_dir/" && rm -f "$out_dir/.gitrepo"
    git -C "$out_dir" init --quiet
    git -C "$out_dir" add -A
    git -C "$out_dir" commit --quiet -m "release"
    git -C "$out_dir" push --quiet "$WORK/suede.repoB.git" HEAD:refs/heads/release )
  b="$(git --git-dir="$WORK/suede.repoB.git" rev-parse release)"
  [[ -f "$WORK/suede.repoB/release/.suede/.dependencies/suede.repoC.repoB.gitrepo" ]] \
    && log_pass "suede.repoB publishes its record as suede.repoC.repoB" || { log_failure "no suede.repoC.repoB record"; return 1; }

  graph_make_project "$WORK" suede.repoA --dependency
  ( cd "$WORK/suede.repoA"
    bash "$INSTALL" --repo "$(graph_remote "$WORK" suede.repoB)" > "$WORK/a-install.txt" 2>&1
    # Run the recipe the installer printed, from the root, as a person would.
    bash <(grep -E '^ *(bash <\(curl|ln -s|\(cd )' "$WORK/a-install.txt" | sed 's/^ *//') >/dev/null 2>&1
    git add -A; git commit --quiet -m "install suede.repoB" )
  graph_assert_link "$WORK/suede.repoA/suede.repoB.repoA" suede.repoB "suede.repoA declares suede.repoB.repoA" || return 1
  [[ -d "$WORK/suede.repoA/suede.repoC" ]] && log_pass "the recipe installed suede.repoC" || { cat "$WORK/a-install.txt" >&2; return 1; }
  graph_assert_link "$WORK/suede.repoA/suede.repoC.repoB" suede.repoC "and linked suede.repoB's own edge to it" || return 1
  graph_assert_link "$WORK/suede.repoA/suede.repoC.repoA" suede.repoC "and declared the transitive install as suede.repoC.repoA" || return 1

  out="$( cd "$WORK/suede.repoA" && DRY_RUN=1 bash "$PUSH_RELEASE" 2>&1 )" \
    && log_pass "the publish guard passes" || { log_failure "the guard failed"; printf '%s\n' "$out" >&2; return 1; }
  local records="$WORK/suede.repoA/release/.suede/.dependencies"
  [[ -f "$records/suede.repoB.repoA.gitrepo" && -f "$records/suede.repoC.repoA.gitrepo" ]] \
    && log_pass "extract detected both shortened declarations" || { ls "$records" >&2; return 1; }
  [[ "$(git config -f "$records/suede.repoB.repoA.gitrepo" subrepo.commit)" == "$b" ]] \
    && log_pass "and pinned what is installed" || return 1
  out="$( cd "$WORK/suede.repoA" && bash .suede/core/diff.sh 2>&1 )" || { log_failure "diff.sh failed: $out"; return 1; }
  graph_assert_contains "$out" '2 checked' "and diff.sh compares both against their pins"
}

run_test_suite --setup setup --cleanup cleanup \
  an_honest_tree_passes_the_guard \
  the_records_are_refreshed_and_committed \
  a_diverged_release_dependency_refuses_to_publish \
  a_missing_sibling_refuses_to_publish \
  a_stale_release_core_is_named_rather_than_worked_around \
  an_ssh_remote_is_compared_over_https_when_ssh_is_unavailable \
  suede_prefixed_names_are_detected_and_resolve_downstream
