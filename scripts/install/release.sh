#!/usr/bin/env bash
#
# Bootstrap for the suede installer.
#
#   bash <(curl -fsSL https://suede.sh/install/release) --repo OWNER/REPO
#   bash <(curl -fsSL https://suede.sh/install/release) --repo OWNER/REPO --dev
#   bash <(curl -fsSL https://suede.sh/install/release) --repo OWNER/REPO --vendor
#
# The default installs a release dependency: prefixed, flat at the root, and
# recorded in your manifest. --dev installs a development dependency (no
# prefix, nothing recorded, its own dependencies not doubled as yours), and
# --vendor installs a vendored one (source and all into release/<name>, with
# its dependencies vendored beside it).
#
# Finds a Python 3.9+, downloads scripts/suede.py, and hands it the arguments.
# Everything the installer does lives in that one readable file; this script
# exists only because the documented one-liner is baked into every dependency
# README the initialize workflow has ever generated.
#
# Run `suede.py install --help` for the full option list.
#
# Overrides (used by the test suite):
#   SUEDE_PY   where to fetch suede.py from; a path or file:// URL works

set -euo pipefail

readonly SUEDE_PY="${SUEDE_PY:-https://suede.sh/suede}"
readonly MINIMUM_PYTHON="3.9"

die() { printf 'install/release: %s\n' "$*" >&2; exit 1; }

# The first interpreter new enough to run the installer. `python3` is tried
# first so an activated virtualenv wins; the numbered names cover systems where
# `python3` is older than what is also installed alongside it.
find_python() {
  local candidate
  for candidate in python3 python3.13 python3.12 python3.11 python3.10 python3.9 python; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)' \
      >/dev/null 2>&1 || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

fetch() {
  case "$1" in
    file://*) cp "${1#file://}" "$2" ;;
    /*)       cp "$1" "$2" ;;
    *)        curl -fsSL "$1" -o "$2" ;;   # -f: a 404 body must never reach python
  esac
}

# v1 flags that still appear in generated READMEs. `--branch` named the branch
# holding release/.gitrepo, a lookup v2 does not perform: it resolves the
# release branch on the remote directly.
translate() {
  ARGUMENTS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -b|--branch)
        printf 'install/release: ignoring "%s %s" - v2 resolves the release branch directly\n' \
          "$1" "${2-}" >&2
        shift 2
        ;;
      -d|--destination)
        [[ -n "${2-}" ]] || die "missing argument to $1"
        ARGUMENTS+=(--name "$(basename "${2%/}")")
        [[ "$(dirname "${2%/}")" == "." ]] || ARGUMENTS+=(--target "$(dirname "${2%/}")")
        shift 2
        ;;
      *)
        ARGUMENTS+=("$1")
        shift
        ;;
    esac
  done
}

command -v curl >/dev/null 2>&1 || die "curl not found"

PYTHON="$(find_python)" || die \
  "no python3 >= $MINIMUM_PYTHON found. macOS ships one with the Command Line Tools
  (xcode-select --install); on Linux install the python3 package for your distribution."

WORKSPACE="$(mktemp -d)"
trap 'rm -rf "$WORKSPACE"' EXIT

fetch "$SUEDE_PY" "$WORKSPACE/suede.py" || die "could not download the installer from $SUEDE_PY"

translate "$@"

# Not `exec`: the installer's exit code is the contract (see suede.py's Exit
# table), and the trap above still has a workspace to remove.
STATUS=0
"$PYTHON" "$WORKSPACE/suede.py" install ${ARGUMENTS[@]+"${ARGUMENTS[@]}"} || STATUS=$?
exit "$STATUS"
