#!/usr/bin/env bash
set -euo pipefail

# Populates ./release/.suede/.dependencies with:
#  - one <folder>.gitrepo file for each subrepo dependency. A subrepo dependency
#    is a symlink living at the repo root that points to a folder inside
#    <root>/.suede. If that symlink is dangling (its target folder no longer
#    exists) this script fails. If the target folder contains a .gitrepo it is
#    copied to <folder>.gitrepo (named after the target folder).
#  - a minimal package.json containing only { "dependencies": { ... } } if package.json exists
#  - a requirements.txt copy if requirements.txt exists
#
# Safe to run on GitHub runners and locally. Existing files are overwritten.

ROOT="$PWD"
DEST_DIR="$ROOT/release/.suede/.dependencies"

log() { printf '[populate-deps] %s\n' "$*"; }

# Ensure destination directory exists
mkdir -p "$DEST_DIR"
log "Ensured destination directory: $DEST_DIR"

# Copy .gitrepo files for each subrepo dependency.
#
# A subrepo dependency is a symlink that lives at the root of the repo and points
# to a folder inside <root>/.suede:
#   - If the symlink is dangling (its target no longer exists) we fail, reporting
#     the dangling subrepo dependency.
#   - If the symlink is valid and the target folder contains a .gitrepo, that
#     .gitrepo is copied to $DEST_DIR/<folder>.gitrepo (named after the target).
#
# Args: $1 = repo root to scan
copy_gitrepo_files() {
  local search_dir="$1"
  [[ -d "$search_dir" ]] || return 0

  local suede_dir="$search_dir/.suede"

  log "Scanning for subrepo dependency symlinks in: $search_dir"
  shopt -s nullglob dotglob
  for link in "$search_dir"/* ; do
    # Only consider symlinks at the root.
    [[ -L "$link" ]] || continue

    # Resolve the link's target to an absolute path (works even when dangling).
    local target
    target="$(readlink "$link")"
    case "$target" in
      /*) ;;                              # already absolute
      *)  target="$search_dir/$target" ;; # relative -> resolve against root
    esac

    # Only treat symlinks that point inside <root>/.suede as subrepo deps.
    case "$target" in
      "$suede_dir"/*) ;;
      *) continue ;;
    esac

    local link_name target_name
    link_name="$(basename "$link")"
    target_name="$(basename "$target")"

    # Dangling dependency: the target folder no longer exists -> fail.
    if [[ ! -e "$link" ]]; then
      log "ERROR: dangling subrepo dependency '$link_name' -> '$target' (target folder no longer exists)"
      exit 1
    fi

    # Skip if a .suedeignore sits in the target folder.
    if [[ -f "$target/.suedeignore" ]]; then
      log "Skipped '$link_name' (found .suedeignore in $target)"
      continue
    fi

    local src="$target/.gitrepo"
    if [[ -f "$src" ]]; then
      local dst="$DEST_DIR/$target_name.gitrepo"
      cp -f "$src" "$dst"
      log "Copied $src -> $dst"
    else
      log "Skipped '$link_name' (no .gitrepo in $target)"
    fi
  done
  shopt -u nullglob dotglob
}

# Discover subrepo dependencies (root symlinks into .suede) and copy their .gitrepo files.
copy_gitrepo_files "$ROOT"

# Extract only "dependencies" from package.json, write to release/.suede/.dependencies/package.json
pkg_src="$ROOT/package.json"
pkg_dst="$DEST_DIR/package.json"
if [[ -f "$pkg_src" ]]; then
  log "Found package.json; extracting dependencies"
  if command -v jq >/dev/null 2>&1; then
    jq '{dependencies: (.dependencies // {})}' "$pkg_src" > "$pkg_dst"
  elif command -v node >/dev/null 2>&1; then
    node -e 'const fs=require("fs");const p=JSON.parse(fs.readFileSync("package.json","utf8"));console.log(JSON.stringify({dependencies:p.dependencies||{}}, null, 2));' > "$pkg_dst"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY' > "$pkg_dst"
import json
with open("package.json","r",encoding="utf-8") as f:
    p=json.load(f)
print(json.dumps({"dependencies": p.get("dependencies", {})}, indent=2))
PY
  else
    log "WARNING: Could not find jq, node, or python3; skipping package.json dependency extraction"
  fi
  [[ -f "$pkg_dst" ]] && log "Wrote $pkg_dst"
fi

# Copy requirements.txt if present
req_src="$ROOT/requirements.txt"
req_dst="$DEST_DIR/requirements.txt"
if [[ -f "$req_src" ]]; then
  cp -f "$req_src" "$req_dst"
  log "Copied $req_src -> $req_dst"
fi

log "Done."
