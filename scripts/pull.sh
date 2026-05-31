#!/usr/bin/env bash
#
# Pull git-subrepo directories.
#
# Usage:
#   ./pull.sh [OPTIONS] [TARGET ...]
#
# TARGET is forwarded directly to find.sh and follows find.sh semantics.
# If omitted, find.sh default behavior is used.
#
# Only top-level subrepos are pulled (see helpers.sh and find.sh --top-level): a
# .gitrepo nested inside another subrepo references history from a different
# repository, which `git subrepo pull` cannot resolve here.
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

usage() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
  exit 0
}

source <(curl -fsSL "$EXTERNAL_SCRIPT_HELPERS")

subrepo_parse_args "$@"
subrepo_resolve_root
subrepo_collect_dirs
subrepo_foreach pull
