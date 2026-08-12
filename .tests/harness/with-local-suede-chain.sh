# A complete suede topology on LOCAL bare repos (no network) for the
# mutation-heavy flows (init / sync / upstream round trip). Complements
# with-single-example-txt-file.sh, which uses a real read-only remote branch.
TESTS_HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_HARNESS_DIR/color-logging.sh"
source "$TESTS_HARNESS_DIR/normalize.sh"

export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-suede-test}"   GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-t@t}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-suede-test}" GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-t@t}"

# Seed a bare "remote" with a release branch (library) + a minimal main branch.
chain_seed_remote() { # <bare> <seeddir>
  local bare="$1" seed="$2"
  git init --quiet --bare "$bare"
  git init --quiet "$seed"
  ( cd "$seed"
    git remote add origin "$bare"
    mkdir -p lib; printf 'export const v = 1;\n' > lib/index.js
    git add .; git commit --quiet -m "release: initial library"; git branch -m release
    git push --quiet origin release
    git checkout --quiet --orphan main; git rm -rq --cached . >/dev/null 2>&1 || true; rm -rf lib
    printf '# dependency\n' > README.md; git add README.md; git commit --quiet -m "main: initial"
    git push --quiet origin main )
  git -C "$bare" symbolic-ref HEAD refs/heads/main
}

# A consumer that vendors the dependency's release into deps/foo.
chain_make_consumer() { # <bare> <consumer>
  local bare="$1" cons="$2"
  git init --quiet "$cons"
  ( cd "$cons"
    printf 'console.log(1)\n' > app.js; git add app.js; git commit --quiet -m "consumer init"
    git subrepo clone "$bare" -b release deps/foo --quiet )
}

# Stands in for this library's own dependency/{main,release}/{core,workflows}
# branches: everything a dependency vendors from suede. Init clones the cores;
# the workflows arrive with the template, which chain_make_template_repo does.
chain_seed_library_branches() { # <bare> <work>
  local bare="$1" work="$2" branch
  git init --quiet --bare "$bare"
  git init --quiet "$work"
  ( cd "$work"
    printf 'maintainer tools v1\n' > push-release.sh
    git add -A; git commit --quiet -m "main core v1"; git branch -m dependency/main/core
    git push --quiet "$bare" dependency/main/core
    for branch in dependency/release/core dependency/main/workflows dependency/release/workflows; do
      git checkout --quiet --orphan "$branch"
      git rm -rq --cached . >/dev/null 2>&1 || true; rm -f ./*.sh ./*.yml sync 2>/dev/null || true
      case "$branch" in
        */core)      printf 'consumer tools v1\n' > sync ;;
        */workflows) printf 'name: %s v1\n' "${branch##*/}" > subrepo-push-release.yml ;;
      esac
      git add -A; git commit --quiet -m "$branch v1"
      git push --quiet "$bare" "$branch"
    done )
}

# Publish a new commit on one of those branches, as the library moving on.
chain_advance_library_branch() { # <bare> <work> <branch> <text>
  ( cd "$2"
    git checkout --quiet "$3"
    case "$3" in
      */core)      printf '%s\n' "$4" > sync ;;
      */workflows) printf '%s\n' "$4" > subrepo-push-release.yml ;;
    esac
    git add -A; git commit --quiet -m "$3: $4"
    git push --quiet "$1" "$3" )
}

# ---- assertions in the harness style (log_pass/log_failure, return 0/1) -----
assert_file_matches() { # <file> <ere> [label]
  local file="$1" ere="$2" label="${3:-$1 matches /$2/}"
  if [[ -f "$file" ]] && grep -qE "$ere" "$file"; then log_pass "$label"; return 0; fi
  log_failure "$label"; [[ -f "$file" ]] && log_info "actual: $(tr '\n' '|' <"$file")"; return 1
}
assert_release_matches() { # <bare> <path-in-release> <ere> [label]
  local bare="$1" path="$2" ere="$3" label="${4:-release:$2 matches /$3/}"
  if git --git-dir="$bare" cat-file -p "release:$path" 2>/dev/null | grep -qE "$ere"; then
    log_pass "$label"; return 0; fi
  log_failure "$label"; return 1
}
assert_clean_tree() { # [label]
  if [[ -z "$(git status --porcelain)" ]]; then log_pass "${1:-working tree is clean}"; return 0; fi
  log_failure "${1:-working tree is clean}"; git status --porcelain | sed 's/^/    /'; return 1
}

# ---- offline GitHub-shaped origin (for degit / install-gitrepo) -------------
# Lets the GitHub-fetching scripts run with zero network: a real local git repo
# provides the content, and a file:// tree mirrors the slice of the GitHub REST
# API that degit touches (tarball download + commit-exists check).
readonly CHAIN_OWNER="suede-test"
readonly CHAIN_REPO="example"
readonly CHAIN_FILE="example.txt"
CHAIN_COMMITS=()       # (first_sha second_sha) — set by chain_make_offline_origin
CHAIN_API_ORIGIN=""    # file://<mirror> — pass as GITHUB_API_ORIGIN to degit
CHAIN_REMOTE=""        # https://github.com/<owner>/<repo>.git — for .gitrepo files

chain_make_offline_origin() { # <dir>
  local src="$1/src" mirror="$1/api" i sha base
  git init --quiet "$src"
  ( cd "$src"
    printf 'first commit'  > "$CHAIN_FILE"; git add .; git commit --quiet -m "first commit"
    printf 'second commit' > "$CHAIN_FILE"; git commit --quiet -am "second commit" )
  CHAIN_COMMITS=( "$(git -C "$src" rev-parse HEAD~1)" "$(git -C "$src" rev-parse HEAD)" )
  base="$mirror/repos/$CHAIN_OWNER/$CHAIN_REPO"
  mkdir -p "$base/tarball" "$base/commits"
  for i in 0 1; do
    sha="${CHAIN_COMMITS[$i]}"
    # GitHub-shaped tarball: exactly one top-level dir, which degit strips.
    git -C "$src" archive --format=tar.gz --prefix="$CHAIN_REPO-$sha/" "$sha" > "$base/tarball/$sha"
    : > "$base/commits/$sha"   # existence stub: `curl -f` succeeds iff present
  done
  CHAIN_API_ORIGIN="file://$mirror"
  CHAIN_REMOTE="https://github.com/$CHAIN_OWNER/$CHAIN_REPO.git"
}

# A .gitrepo body that points at the offline origin, for commit index 0|1.
chain_gitrepo_for() { # <index>
  printf '; DO NOT EDIT\n;\n[subrepo]\n\tremote = %s\n\tbranch = release\n\tcommit = %s\n\tparent = \n\tmethod = merge\n' \
    "$CHAIN_REMOTE" "${CHAIN_COMMITS[$1]}"
}

# Assert a degit/install destination holds the expected example.txt for index 0|1.
assert_offline_contents() { # <dir> <index>
  local f="$1/$CHAIN_FILE" want
  case "$2" in 0) want="first commit";; 1) want="second commit";; *) want="";; esac
  if [[ -f "$f" && "$(strip_cr "$(<"$f")")" == "$want" ]]; then
    log_pass "$1 has expected contents for commit index $2"; return 0
  fi
  log_failure "$1 contents mismatch for index $2"; [[ -f "$f" ]] && log_info "actual: $(<"$f")"; return 1
}
