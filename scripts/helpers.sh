#!/usr/bin/env bash
# scripts/helpers.sh — shared scaffolding for pull.sh and push.sh.
#
# Sourced by those entrypoints (not executed directly). It centralises the parts
# that must stay identical between pull and push — argument parsing, repo-root
# resolution, the --top-level find invocation, the dry-run command runner, and
# the per-subrepo loop — so the two can never silently drift again.
#
# The caller must define EXTERNAL_SCRIPT_BASE and a usage() function before
# sourcing. These functions read/write the caller's shell variables:
#   DRY_RUN, TARGET_ARGS[], DIRS[], REPO_ROOT
#
# API:
#   subrepo_parse_args "$@"   -> sets DRY_RUN, TARGET_ARGS
#   subrepo_resolve_root      -> sets REPO_ROOT (exits if not in a git repo)
#   subrepo_collect_dirs      -> sets DIRS to top-level subrepos (exits if none)
#   subrepo_run_cmd CMD...    -> dry-run-aware command runner
#   subrepo_foreach VERB      -> `git subrepo VERB` over DIRS, with summary

: "${EXTERNAL_SCRIPT_BASE:?EXTERNAL_SCRIPT_BASE must be set before sourcing helpers.sh}"
readonly EXTERNAL_SCRIPT_FIND="${EXTERNAL_SCRIPT_BASE}/find.sh"

DRY_RUN=false
declare -a TARGET_ARGS=()
declare -a FIND_FILTER=()      # scope flags forwarded verbatim to find.sh
declare -a DIRS=()
REPO_ROOT=""

subrepo_parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry|--dry-run)     DRY_RUN=true; shift ;;
      --internal|--external) FIND_FILTER+=("$1"); shift ;;   # forwarded to find.sh
      -h|--help)           usage ;;                 # usage() lives in the entrypoint
      -*)                  printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
      *)                   TARGET_ARGS+=("$1"); shift ;;
    esac
  done
}

subrepo_resolve_root() {
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
    printf 'Not inside a git repository.\n' >&2
    exit 1
  }
}

# Populate DIRS with repo-root-relative, top-level subrepo paths.
# --top-level excludes subrepos nested inside another subrepo (see find.sh): a
# nested .gitrepo references history from the repo it was cloned in, which this
# consuming repo cannot resolve, so neither pull nor push can act on it.
subrepo_collect_dirs() {
  local abs_dir
  while IFS= read -r abs_dir; do
    [[ -z "$abs_dir" ]] && continue
    [[ "$abs_dir" == "$REPO_ROOT"/* ]] || continue
    DIRS+=("${abs_dir#"$REPO_ROOT"/}")
  done < <(bash <(curl -fsSL "$EXTERNAL_SCRIPT_FIND") --top-level \
            ${FIND_FILTER[@]+"${FIND_FILTER[@]}"} ${TARGET_ARGS[@]+"${TARGET_ARGS[@]}"})

  if [[ ${#DIRS[@]} -eq 0 ]]; then
    printf 'No top-level subrepos found.\n' >&2
    exit 0
  fi
}

subrepo_run_cmd() {
  if $DRY_RUN; then
    printf '[dry-run] %s\n' "$*" >&2
  else
    (cd "$REPO_ROOT" && "$@")
  fi
}

# Run `git subrepo VERB` over every DIR, then print a summary. VERB is "pull" or
# "push"; messages derive from it (Pull/Push -> Pulled/Pushed, "Pull failed" …).
subrepo_foreach() {
  local verb="$1" dir
  for dir in "${DIRS[@]}"; do
    subrepo_run_cmd git subrepo "$verb" "$dir" || {
      printf '%s failed for %s\n' "${verb^}" "$dir" >&2
      exit 1
    }
  done
  if $DRY_RUN; then
    printf 'Dry run complete: %d subrepo(s).\n' "${#DIRS[@]}" >&2
  else
    printf '%sed %d subrepo(s).\n' "${verb^}" "${#DIRS[@]}" >&2
  fi
}
