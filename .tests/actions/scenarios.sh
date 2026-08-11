#!/usr/bin/env bash
#
# Tier C: the five things only a forge can answer.
#
#   .tests/actions/bootstrap.sh && .tests/actions/scenarios.sh
#
# Everything else about these workflows — extraction, the divergence guard,
# `check`, the PR description, the early-return path — is already covered at
# Layer 2 against local bare repos, with no runner and no container. What is
# left, and what is here, is: does the trigger fire, do permissions work, does
# the token flow, does the PR get created.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/.env" 2>/dev/null || { echo "run bootstrap.sh first" >&2; exit 1; }
source "$SUEDE_ROOT/.tests/harness/color-logging.sh"
source "$SUEDE_ROOT/.tests/harness/runner.sh"

readonly ORG="$GITEA_ORG"
readonly DEP_LIB="$GITEA_URL/$ORG/dep-lib.git"
readonly PUSH_URL="http://$GITEA_ADMIN:$GITEA_PASSWORD@localhost:3000/$ORG"

WORK=""

api() {
  local method="$1" path="$2"; shift 2
  curl -fsS -X "$method" -H "Content-Type: application/json" \
    -H "Authorization: token $GITEA_TOKEN" "$GITEA_URL/api/v1$path" "$@"
}

git_at() { git -C "$1" "${@:2}"; }

# A dependency library, shaped exactly as a real one: `main` carrying release/
# as a subrepo, plus the workflows under test vendored into .suede/core.
seed_dep_lib() {
  local repo="$WORK/dep-lib"
  git init --quiet --initial-branch=main "$repo"
  git_at "$repo" config user.email tier-c@example.test
  git_at "$repo" config user.name "tier c"

  mkdir -p "$repo/release" "$repo/.suede/core" "$repo/.github/workflows"
  printf 'export const version = 1;\n' > "$repo/release/index.ts"
  cp "$SUEDE_ROOT/dependency/main/core/"* "$repo/.suede/core/"
  cp "$SUEDE_ROOT/dependency/main/workflows/subrepo-push-release.yml" "$repo/.github/workflows/"

  git_at "$repo" add -A
  git_at "$repo" commit --quiet -m "seed dep-lib"
  git_at "$repo" push --quiet "$PUSH_URL/dep-lib.git" main

  # An orphan `release` branch, which is what consumers actually resolve.
  git_at "$repo" checkout --quiet --orphan release
  git_at "$repo" rm -rq --cached .
  find "$repo" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
  printf 'export const version = 1;\n' > "$repo/index.ts"
  git_at "$repo" add -A
  git_at "$repo" commit --quiet -m "seed release"
  git_at "$repo" push --quiet "$PUSH_URL/dep-lib.git" release
  git_at "$repo" checkout --quiet main
}

wait_for_run() {
  local repo="$1" attempt
  for attempt in $(seq 1 60); do
    local status
    status="$(api GET "/repos/$ORG/$repo/actions/tasks?limit=1" 2>/dev/null \
      | python3 -c 'import json,sys
try:
    tasks = json.load(sys.stdin).get("workflow_runs") or []
    print(tasks[0]["status"] if tasks else "none")
except Exception:
    print("none")')"
    [[ "$status" == "success" || "$status" == "failure" ]] && { printf '%s\n' "$status"; return 0; }
    sleep 3
  done
  printf 'timeout\n'
}

release_branch_content() {
  git ls-remote "$PUSH_URL/dep-lib.git" refs/heads/release | awk '{print $1}'
}

setup() {
  WORK="$(mktemp -d)"
  seed_dep_lib
}
cleanup() { [[ -n "${WORK:-}" && -d "$WORK" ]] && rm -rf "$WORK"; }

a_push_to_main_syncs_the_release_branch() {
  local repo="$WORK/dep-lib" before
  before="$(release_branch_content)"
  printf 'export const version = 2;\n' > "$repo/release/index.ts"
  git_at "$repo" commit --quiet -am "feat: version 2"
  git_at "$repo" push --quiet "$PUSH_URL/dep-lib.git" main

  [[ "$(wait_for_run dep-lib)" == "success" ]] || { log_failure "the push workflow succeeded"; return 1; }
  [[ "$(release_branch_content)" != "$before" ]] || { log_failure "release advanced"; return 1; }
  log_pass "a push to main advanced the release branch"
}

a_divergent_release_dependency_leaves_release_untouched() {
  local repo="$WORK/dep-lib" before
  before="$(release_branch_content)"

  # A release dependency whose bytes no longer match the commit it points at.
  mkdir -p "$repo/dep-lib.widget"
  printf '[subrepo]\n\tremote = %s\n\tbranch = release\n\tcommit = %s\n' \
    "$DEP_LIB" "$(git ls-remote "$PUSH_URL/dep-lib.git" refs/heads/release | awk '{print $1}')" \
    > "$repo/dep-lib.widget/.gitrepo"
  printf 'diverged\n' > "$repo/dep-lib.widget/index.ts"
  printf 'export const version = 3;\n' > "$repo/release/index.ts"
  git_at "$repo" add -A
  git_at "$repo" commit --quiet -m "feat: version 3 with a diverged dependency"
  git_at "$repo" push --quiet "$PUSH_URL/dep-lib.git" main

  [[ "$(wait_for_run dep-lib)" == "failure" ]] || { log_failure "the guard failed the run"; return 1; }
  [[ "$(release_branch_content)" == "$before" ]] || { log_failure "release stayed put"; return 1; }
  log_pass "a divergent release dependency stopped the publish and left release untouched"
}

run_test_suite --setup setup --cleanup cleanup \
  a_push_to_main_syncs_the_release_branch \
  a_divergent_release_dependency_leaves_release_untouched
