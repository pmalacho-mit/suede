#!/usr/bin/env bash
#
# Pull and push git-subrepo directories.
#
# Usage:
#   ./push.sh [OPTIONS] [TARGET]
#
# TARGET can be:
#   - A subrepo name (e.g. "my-dep")     — matched by basename anywhere in the tree
#   - A directory path (e.g. "libs/")    — recursively searched for .gitrepo files
#   - Omitted                            — searches from the repo root
#
# Options:
#   --dry, --dry-run          Print the commands that would run without executing them
#   --omit <name|path>        Skip a subrepo by name or path (repeatable)
#   -h, --help                Show this help message

set -euo pipefail

# ---------------------------------------------------------------------------
# Colour helpers (only when stderr is a TTY)
# ---------------------------------------------------------------------------
if [[ -t 2 ]]; then
  BOLD=$'\033[1m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  CYAN=$'\033[36m'
  RED=$'\033[31m'
  DIM=$'\033[2m'
  RESET=$'\033[0m'
else
  BOLD='' GREEN='' YELLOW='' CYAN='' RED='' DIM='' RESET=''
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()    { printf "%b%s%b\n"    "$BOLD"   "$*" "$RESET" >&2; }
success() { printf "%b✓ %s%b\n" "$GREEN"  "$*" "$RESET" >&2; }
warn()    { printf "%b⚠ %s%b\n" "$YELLOW" "$*" "$RESET" >&2; }
err()     { printf "%b✗ %s%b\n" "$RED"    "$*" "$RESET" >&2; }
dry()     { printf "%b[dry-run]%b %s\n"   "$CYAN" "$RESET" "$*" >&2; }
sep()     { printf "%b%s%b\n" "$DIM" "──────────────────────────────────────" "$RESET" >&2; }

usage() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
  exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
DRY_RUN=false
TARGET=""
declare -a OMIT_LIST=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry|--dry-run)
      DRY_RUN=true
      shift
      ;;
    --omit)
      [[ -z "${2-}" ]] && { err "--omit requires an argument"; exit 1; }
      OMIT_LIST+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    -*)
      err "Unknown option: $1"
      exit 1
      ;;
    *)
      if [[ -n "$TARGET" ]]; then
        err "Unexpected argument: $1 (TARGET already set to '$TARGET')"
        exit 1
      fi
      TARGET="$1"
      shift
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Resolve the repo root so git subrepo commands always run from there
# ---------------------------------------------------------------------------
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  err "Not inside a git repository."
  exit 1
}

# ---------------------------------------------------------------------------
# Discover subrepo directories
# ---------------------------------------------------------------------------
# Returns: newline-separated list of paths relative to REPO_ROOT (no trailing /)

find_subrepos() {
  local search_root="$1"
  find "$search_root" -name ".gitrepo" -type f \
    | sed 's|/\.gitrepo$||' \
    | sed "s|^\./||" \
    | sort -u
}

resolve_dirs() {
  local -n _out=$1   # nameref to output array

  if [[ -z "$TARGET" ]]; then
    # No target — search entire repo
    while IFS= read -r d; do _out+=("$d"); done \
      < <(find_subrepos "$REPO_ROOT")
  else
    # Check if TARGET is an exact name match (basename) anywhere in the tree
    local by_name
    by_name=$(find_subrepos "$REPO_ROOT" | awk -F'/' -v t="$TARGET" '$NF == t')

    if [[ -n "$by_name" ]]; then
      while IFS= read -r d; do _out+=("$d"); done <<< "$by_name"
    else
      # Treat TARGET as a directory path and search recursively within it
      local search_path="$REPO_ROOT/$TARGET"
      if [[ ! -d "$search_path" ]]; then
        err "No subrepo named '$TARGET' found, and '$TARGET' is not a directory."
        exit 1
      fi
      while IFS= read -r d; do _out+=("$d"); done \
        < <(find_subrepos "$search_path")
    fi
  fi
}

declare -a ALL_DIRS=()
resolve_dirs ALL_DIRS

if [[ ${#ALL_DIRS[@]} -eq 0 ]]; then
  warn "No subrepos found${TARGET:+ for '$TARGET'}."
  exit 0
fi

# ---------------------------------------------------------------------------
# Apply omit list
# ---------------------------------------------------------------------------
is_omitted() {
  local dir="$1" base
  base=$(basename "$dir")

  # Normalize discovered dir so omit rules can be expressed as either
  # repo-relative paths (preferred) or absolute paths under REPO_ROOT.
  local dir_rel="$dir"
  if [[ "$dir_rel" == "$REPO_ROOT"/* ]]; then
    dir_rel="${dir_rel#"$REPO_ROOT"/}"
  fi

  for omit in "${OMIT_LIST[@]}"; do
    local rule="$omit"
    rule="${rule%/}"
    rule="${rule#./}"

    # Allow absolute omit paths as long as they are inside this repo.
    if [[ "$rule" == "$REPO_ROOT"/* ]]; then
      rule="${rule#"$REPO_ROOT"/}"
    fi

    # Match by basename, exact path, suffix path, or directory-tree prefix.
    if [[ "$base" == "$rule" \
       || "$dir_rel" == "$rule" \
       || "$dir_rel" == "$rule"/* \
       || "$dir_rel" == */"$rule" \
       || "$dir_rel" == */"$rule"/* ]]; then
      return 0
    fi
  done
  return 1
}

declare -a DIRS=()
for d in "${ALL_DIRS[@]}"; do
  if is_omitted "$d"; then
    warn "Omitting: $d"
  else
    DIRS+=("$d")
  fi
done

if [[ ${#DIRS[@]} -eq 0 ]]; then
  warn "All discovered subrepos were omitted."
  exit 0
fi

# ---------------------------------------------------------------------------
# Preview
# ---------------------------------------------------------------------------
info "Subrepos to process (${#DIRS[@]}):"
for d in "${DIRS[@]}"; do
  printf "  %s\n" "$d" >&2
done
printf "\n" >&2

$DRY_RUN && info "[dry-run mode — no commands will be executed]" && printf "\n" >&2

# ---------------------------------------------------------------------------
# Run pull then push for each subrepo
# ---------------------------------------------------------------------------
run_cmd() {
  # Run a command from the repo root, respecting --dry-run
  local desc="$1"; shift
  if $DRY_RUN; then
    dry "$*"
  else
    printf "%b+ %s%b\n" "$DIM" "$*" "$RESET" >&2
    (cd "$REPO_ROOT" && "$@")
  fi
}

FAILED=()

for dir in "${DIRS[@]}"; do
  sep
  info "Processing: $dir"

  # --- pull ---
  if run_cmd "pull" git subrepo pull "$dir"; then
    $DRY_RUN || success "Pulled $dir"
  else
    warn "Pull failed for $dir — skipping push for this subrepo"
    FAILED+=("$dir (pull)")
    continue
  fi

  # --- push ---
  if run_cmd "push" git subrepo push "$dir"; then
    $DRY_RUN || success "Pushed $dir"
  else
    warn "Push failed for $dir"
    FAILED+=("$dir (push)")
  fi

  printf "\n" >&2
done

sep

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [[ ${#FAILED[@]} -gt 0 ]]; then
  err "Completed with errors:"
  for f in "${FAILED[@]}"; do
    printf "  %b✗ %s%b\n" "$RED" "$f" "$RESET" >&2
  done
  exit 1
else
  $DRY_RUN \
    && info "Dry run complete — ${#DIRS[@]} subrepo(s) would be processed." \
    || success "All ${#DIRS[@]} subrepo(s) processed successfully."
fi
