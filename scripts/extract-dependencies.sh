#!/usr/bin/env bash
# Helper to summarize .dependencies for an installed gitrepo and print NEXT STEPS.
# Usage: check-dependencies.sh <dest> <message> [invoke_install_command] [owner] [repo] [commit]

set -euo pipefail

EMIT_ADD_TARGETS=false

if [[ $# -lt 1 ]]; then
  cat >&2 <<USAGE
Usage: $0 <dest> [options]

Arguments:
  <dest>                   Destination directory where the .dependencies folder (if any) resides

Options:
  --message <text>                  Header message to print (defaults to "Dependencies")
  --invoke-install-command <cmd>    Command to show how to install nested subrepos (default: bash <(curl https://suede.sh/install-gitrepo))
  --emit-add-targets                Emit a newline-separated list of add targets to stdout (for machine consumption)
USAGE
  exit 1
fi

# Parse optional flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --emit-add-targets)
      EMIT_ADD_TARGETS=true 
      shift 
      ;;
    --message)
      MESSAGE="${2-}"
      shift 2 
      ;;
    --message=*)
      MESSAGE="${1#*=}"
      shift 
      ;;
    --invoke-install-command)
      INVOKE_INSTALL_GITREPO="${2-}"
      shift 2 
      ;;
    --invoke-install-command=*)
      INVOKE_INSTALL_GITREPO="${1#*=}"
      shift 
      ;;
    --)
      shift
      break ;;
    *)
      DEST="$1"
      shift 
      ;;
  esac
done

if [[ -z "${MESSAGE-}" ]]; then
  MESSAGE="Dependencies"
fi

if [[ -z "${INVOKE_INSTALL_GITREPO-}" ]]; then
  INVOKE_INSTALL_GITREPO="bash <(curl https://suede.sh/install-gitrepo)"
fi

# Color and formatting (only enable when stderr is a TTY)
if [[ -t 2 ]]; then
  BOLD=$'\033[1m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  CYAN=$'\033[36m'
  RESET=$'\033[0m'
else
  BOLD=''
  GREEN=''
  YELLOW=''
  CYAN=''
  RESET=''
fi

DEST="${DEST%/}"
DEPS_DIR="$DEST/.dependencies"
NEXT_STEPS_PRINTED=false
subrepos=()
deps_block=""
deps_list=""

if [[ -d "$DEPS_DIR" ]]; then
  PKG_JSON="$DEPS_DIR/package.json"

  # If a package.json exists, extract the "dependencies" object (simple heuristic) and build an install list.
  if [[ -f "$PKG_JSON" ]]; then
    deps_block=$(sed -n '/"dependencies"[[:space:]]*:/,/^[[:space:]]*}/p' "$PKG_JSON" || true)
    if [[ -n "${deps_block//[[:space:]]/}" ]]; then
      deps_list=$(sed -n '/"dependencies"[[:space:]]*:/,/^[[:space:]]*}/p' "$PKG_JSON" | sed '1d;$d' | sed -e 's/^[[:space:]]*"//;s/"[[:space:]]*:[[:space:]]*"/@/;s/",\?$//;s/"$//' | tr '\n' ' ' | sed 's/  */ /g' | sed 's/^ //;s/ $//')
    fi
  fi

  # Find any nested .gitrepo files and collect commands to run them.
  mapfile -t subrepos < <(find "$DEPS_DIR" -type f -name '*.gitrepo' -print 2>/dev/null || true)

  # Print header if we have anything to show.
  if [[ -n "$deps_list" ]] || (( ${#subrepos[@]} )); then
    printf "\n%s%s:%s\n\n" "${BOLD}${YELLOW}" "$MESSAGE" "$RESET" >&2
    NEXT_STEPS_PRINTED=true
  fi

  # Print dependency block if present
  if [[ -n "${deps_block//[[:space:]]/}" ]]; then
    printf "%bThe installed gitrepo has the following npm dependencies:%b\n\n" "$BOLD" "$RESET" >&2
    while IFS= read -r _line; do
      printf "%b  %s%b\n" "$CYAN" "$_line" "$RESET" >&2
    done <<< "$deps_block"
    printf "\n" >&2
  fi

  if [[ -n "$deps_list" ]]; then
    printf "  %sAdd these to your project's package.json and run 'npm install' or install them with the following command:%s\n" "$BOLD" "$RESET" >&2
    printf "    %b%s%b\n\n" "$GREEN" "npm install $deps_list" "$RESET" >&2
  fi

  if (( ${#subrepos[@]} )); then
    printf "%sInstall nested suede dependencies:%s\n" "$BOLD" "$RESET" >&2
    for path in "${subrepos[@]}"; do
      base=$(basename "$path" .gitrepo)
      target="$DEST/../$base"
      printf "  %b%s -d %s %s%b\n" "$CYAN" "$INVOKE_INSTALL_GITREPO" "$target" "$path" "$RESET" >&2
    done
    printf "\n" >&2
  fi
fi

# Ensure header is printed at least once
if [[ "$NEXT_STEPS_PRINTED" != true ]]; then
  printf "\n%s%s:%s\n\n" "${BOLD}${YELLOW}" "$MESSAGE" "$RESET" >&2
fi

# Build git add targets (DEST first, then package.json if deps exist, then nested targets)
add_targets=("$DEST")
PKG_JSON="$DEPS_DIR/package.json"
if [[ -f "$PKG_JSON" ]] && [[ -n "${deps_block//[[:space:]]/}" ]]; then
  add_targets+=("package.json")
fi
if (( ${#subrepos[@]} )); then
  for path in "${subrepos[@]}"; do
    base=$(basename "$path" .gitrepo)
    target="$DEST/../$base"
    add_targets+=("$target")
  done
fi

# If requested, emit the add targets to stdout (machine readable) and exit
if [[ "$EMIT_ADD_TARGETS" == true ]]; then
  for t in "${add_targets[@]}"; do
    printf '%s\n' "$t"
  done
  exit 0
fi