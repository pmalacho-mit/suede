#!/usr/bin/env bash
#
# Show diffs for git-subrepo directories.
#
# Usage:
#   ./diff.sh [OPTIONS] [TARGET ...]
#
# TARGET is forwarded directly to find.sh and follows find.sh semantics.
# If omitted, find.sh default behavior is used.
#
# Options:
#   --force                   Pass --force to `git subrepo branch`
#   -h, --help                Show this help message

set -euo pipefail

readonly EXTERNAL_SCRIPT_BASE="https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts"
readonly EXTERNAL_SCRIPT_FIND="${EXTERNAL_SCRIPT_BASE}/find.sh"

usage() {
	grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
	exit 0
}

FORCE=false
declare -a TARGET_ARGS=()

while [[ $# -gt 0 ]]; do
	case "$1" in
		--force)
			FORCE=true
			shift
			;;
		-h|--help)
			usage
			;;
		-*)
			printf 'Unknown option: %s\n' "$1" >&2
			exit 1
			;;
		*)
			TARGET_ARGS+=("$1")
			shift
			;;
	esac
done

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
	printf 'Not inside a git repository.\n' >&2
	exit 1
}

declare -a SUBREPOS=()
while IFS= read -r abs_dir; do
	[[ -z "$abs_dir" ]] && continue
	[[ "$abs_dir" == "$REPO_ROOT"/* ]] || continue
	SUBREPOS+=("${abs_dir#"$REPO_ROOT"/}")
done < <(bash <(curl -fsSL "$EXTERNAL_SCRIPT_FIND") "${TARGET_ARGS[@]}")

if [[ ${#SUBREPOS[@]} -eq 0 ]]; then
	printf 'No subrepos found.\n' >&2
	exit 0
fi

for subrepo in "${SUBREPOS[@]}"; do
	if $FORCE; then
		(cd "$REPO_ROOT" && git subrepo branch --force "$subrepo")
	else
		(cd "$REPO_ROOT" && git subrepo branch "$subrepo")
	fi

	(cd "$REPO_ROOT" && git diff "subrepo/$subrepo/fetch" "subrepo/$subrepo")
done
