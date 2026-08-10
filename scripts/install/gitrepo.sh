#!/usr/bin/env bash
#
# Deprecated. Kept so a copied `https://suede.sh/install/gitrepo` URL keeps
# working for one release. It translates the v1 arguments and hands over to the
# bootstrap, which runs `suede.py install --gitrepo`.
#
#   was:  bash <(curl https://suede.sh/install/gitrepo) -d vendor/dep dep.gitrepo
#   now:  bash <(curl -fsSL https://suede.sh/install/release) \
#             --gitrepo dep.gitrepo --target vendor --name dep
#
# The v2 installer resolves the whole transitive closure, so it also creates
# the sibling entries this script only ever printed instructions for.

set -euo pipefail

readonly EXTERNAL_SCRIPT_BASE="${SUEDE_SCRIPT_BASE:-https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts}"
readonly BOOTSTRAP="$EXTERNAL_SCRIPT_BASE/install/release.sh"

die() { printf 'install/gitrepo: %s\n' "$*" >&2; exit 1; }

notice() {
  cat >&2 <<'NOTICE'
install/gitrepo is deprecated and will be removed in the next release.
  Use: bash <(curl -fsSL https://suede.sh/install/release) --gitrepo <path|-> [--name <entry>]
NOTICE
}

fetch() {
  case "$1" in
    file://*) cat "${1#file://}" ;;
    /*)       cat "$1" ;;
    *)        curl -fsSL "$1" ;;
  esac
}

# v1 took the .gitrepo as a positional argument and the destination as -d.
translate() {
  ARGUMENTS=()
  local source=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--destination)
        [[ -n "${2-}" ]] || die "missing argument to $1"
        ARGUMENTS+=(-d "$2")
        shift 2
        ;;
      -h|--help) notice; exit 0 ;;
      --) shift ;;
      -|*)
        [[ -z "$source" ]] || die "unexpected argument: $1"
        source="$1"
        shift
        ;;
    esac
  done
  [[ -n "$source" ]] || die "no .gitrepo given; pass a path or - to read stdin"
  ARGUMENTS+=(--gitrepo "$source")
}

notice
translate "$@"

WORKSPACE="$(mktemp -d)"
trap 'rm -rf "$WORKSPACE"' EXIT
fetch "$BOOTSTRAP" > "$WORKSPACE/release.sh" || die "could not fetch $BOOTSTRAP"

STATUS=0
bash "$WORKSPACE/release.sh" ${ARGUMENTS[@]+"${ARGUMENTS[@]}"} || STATUS=$?
exit "$STATUS"
