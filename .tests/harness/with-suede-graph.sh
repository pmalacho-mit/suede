# A graph of suede dependencies on LOCAL bare repos, each with a real `release`
# branch carrying the consumer-facing core (the actual `diff` and `deps.sh`
# from this repository) and `.suede/.dependencies/` records - so the installer,
# deps.sh and the publish flow are exercised against the real manifest format
# with no network.
#
# Written for bash 3.2 as well as 4+: the tests for the scripts that ship to
# consumers run on macOS, which has nothing newer.
#
#   graph_make_dep <work> <name> [<entry>=<remote>@<commit> ...]   -> prints the release commit
#   graph_remote   <work> <name>                                     -> the bare repo's path
#   graph_make_project <work> <name> [--dependency]                  -> a consumer; --dependency
#                                                                       gives it release/.gitrepo
#                                                                       and both cores
TESTS_HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAPH_SUEDE_ROOT="$(cd "$TESTS_HARNESS_DIR/../.." && pwd)"
GRAPH_RELEASE_CORE="$GRAPH_SUEDE_ROOT/dependency/release/core"
GRAPH_MAIN_CORE="$GRAPH_SUEDE_ROOT/dependency/main/core"

export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-suede-test}"   GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-t@t}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-suede-test}" GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-t@t}"

graph_remote() { printf '%s/%s.git' "$1" "$2"; }

graph_vendor_release_core() { # <dir>
  mkdir -p "$1/.suede/core"
  cp "$GRAPH_RELEASE_CORE/diff" "$GRAPH_RELEASE_CORE/deps.sh" "$GRAPH_RELEASE_CORE/sync" "$1/.suede/core/"
}

graph_make_dep() { # <work> <name> [<entry>=<remote>@<commit> ...]
  local work="$1" name="$2"; shift 2
  local bare="$work/$name.git" seed="$work/seed-$name" spec entry rest remote commit record
  git init --quiet --bare "$bare"
  git init --quiet "$seed"
  ( cd "$seed"
    graph_vendor_release_core .
    mkdir -p .suede/.dependencies
    printf 'export const %s = 1;\n' "$name" > index.js
    for spec in "$@"; do
      entry="${spec%%=*}"; rest="${spec#*=}"; remote="${rest%@*}"; commit="${rest##*@}"
      record=".suede/.dependencies/$entry.gitrepo"
      git config -f "$record" subrepo.remote "$remote"
      git config -f "$record" subrepo.branch release
      git config -f "$record" subrepo.commit "$commit"
    done
    git add -A
    git commit --quiet -m "release: $name"
    git branch -m release
    git push --quiet "$bare" release )
  git --git-dir="$bare" symbolic-ref HEAD refs/heads/release
  git --git-dir="$bare" rev-parse release
}

# A new release commit on <name>, changing index.js to <text>. Prints the commit.
graph_advance_dep() { # <work> <name> <text>
  # Two statements: `local` expands every word before assigning any of them.
  local work="$1" name="$2"
  local seed="$work/seed-$name"
  ( cd "$seed"
    printf '%s\n' "$3" > index.js
    git commit --quiet -am "release: $3"
    git push --quiet "$work/$name.git" release )
  git --git-dir="$work/$name.git" rev-parse release
}

graph_make_project() { # <work> <name> [--dependency]
  local work="$1" name="$2" dependency=0
  [[ "${3-}" == "--dependency" ]] && dependency=1
  local dir="$work/$name"
  git init --quiet --bare "$work/$name.git"
  git init --quiet "$dir"
  ( cd "$dir"
    git remote add origin "$work/$name.git"
    printf '# %s\n' "$name" > README.md
    if [[ "$dependency" == 1 ]]; then
      mkdir -p release .suede/core
      graph_vendor_release_core release
      cp "$GRAPH_MAIN_CORE"/*.sh .suede/core/
      git config -f release/.gitrepo subrepo.remote "$work/$name.git"
      git config -f release/.gitrepo subrepo.branch release
      git config -f release/.gitrepo subrepo.commit 0000000000000000000000000000000000000000
      printf 'export * from "./lib.js";\n' > release/index.js
    fi
    git add -A
    git commit --quiet -m "init $name" )
}

# ---- assertions ------------------------------------------------------------
graph_assert_contains() { # <haystack> <ere> <label>
  if grep -qE -- "$2" <<<"$1"; then log_pass "$3"; return 0; fi
  log_failure "$3"; printf '%s\n' "$1" | sed 's/^/    /' >&2; return 1
}
graph_assert_lacks() { # <haystack> <ere> <label>
  if grep -qE -- "$2" <<<"$1"; then
    log_failure "$3"; printf '%s\n' "$1" | sed 's/^/    /' >&2; return 1
  fi
  log_pass "$3"
}
graph_assert_link() { # <link> <target> <label>
  if [[ -L "$1" && "$(readlink "$1")" == "$2" ]]; then log_pass "$3"; return 0; fi
  log_failure "$3 (readlink: $(readlink "$1" 2>/dev/null || echo 'not a symlink'))"; return 1
}
graph_assert_absent() { # <path> <label>
  if [[ ! -e "$1" && ! -L "$1" ]]; then log_pass "$2"; return 0; fi
  log_failure "$2 ($1 exists)"; return 1
}
graph_field() { git config -f "$1/.gitrepo" --get "subrepo.$2" 2>/dev/null || true; }
