#!/usr/bin/env bash
#
# Push git-subrepo directories (after delegating pull to pull.sh).
#
# Usage:
#   ./push.sh [OPTIONS] [TARGET ...]
#
# TARGET is forwarded directly to find.sh and follows find.sh semantics.
# If omitted, find.sh default behavior is used.
#
# Only top-level subrepos are acted on (see helpers.sh and find.sh --top-level);
# this mirrors pull.sh, which push delegates to for the pull phase.
#
# Options:
#   --dry, --dry-run          Print the commands that would run without executing them
#   -h, --help                Show this help message

set -euo pipefail

# ----- External Script Dependencies -----
# SUEDE_SCRIPT_BASE overrides where sibling scripts are fetched from (defaults to
# the hosted main branch); tests point it at a local file:// mirror.
readonly EXTERNAL_SCRIPT_BASE="${SUEDE_SCRIPT_BASE:-https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts}"
readonly EXTERNAL_SCRIPT_HELPERS="${EXTERNAL_SCRIPT_BASE}/helpers.sh"
readonly EXTERNAL_SCRIPT_PULL="${EXTERNAL_SCRIPT_BASE}/pull.sh"

usage() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
  exit 0
}

source <(curl -fsSL "$EXTERNAL_SCRIPT_HELPERS")

subrepo_parse_args "$@"
subrepo_resolve_root
subrepo_collect_dirs

# Pull phase: delegate to pull.sh (forwarding --dry-run + TARGET) before pushing.
declare -a PULL_ARGS=()
$DRY_RUN && PULL_ARGS+=("--dry-run")
PULL_ARGS+=(${TARGET_ARGS[@]+"${TARGET_ARGS[@]}"})

if $DRY_RUN; then
  printf '[dry-run] bash <(curl -fsSL %s) %s\n' "$EXTERNAL_SCRIPT_PULL" "${PULL_ARGS[*]-}" >&2
else
  if ! bash <(curl -fsSL "$EXTERNAL_SCRIPT_PULL") "${PULL_ARGS[@]}"; then
    printf 'Pull phase failed; not continuing to push phase.\n' >&2
    exit 1
  fi
fi

subrepo_foreach push
