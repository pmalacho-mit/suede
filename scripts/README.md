# Scripts

Scripts that share a common prefix are grouped into a folder named after that
prefix, with the prefix stripped from the filename. The hosted URL mirrors the
on-disk path, so `scripts/install/release.sh` is served at both
`https://suede.sh/install/release` and
`https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts/install/release.sh`.

Everything here is bash. There is no interpreter to find and nothing to
download beyond the script itself.

## `install/`

### `install/release.sh`

The installer. One bash script, written for the bash macOS ships (3.2).

```bash
bash <(curl -fsSL https://suede.sh/install/release) --repo OWNER/REPO
```

It installs the dependency's `release` branch into `./<name>` in the directory
you run it from, writes a `.gitrepo` there, declares the install if this
repository is a suede dependency (a `<name><sep><repo>` symlink beside the
folder), stages everything without committing, and runs the dependency's own
`deps.sh` so you see what it needs beside it. [INSTALL.md](../INSTALL.md) is
the full description, including every flag:

```
--repo <OWNER/REPO | url>   required; OWNER/REPO means github.com
--at <commit>               install this commit instead of the branch tip
--branch <name>             install from this branch (default: release)
--sep <text>                separator in the declaring symlink (default: __ in a
                            repository named suede__<name>, else .)
--name <folder>             install under this name instead of the repo's
--prefix <text>             prepend to the folder name
--suffix <text>             append to the folder name
--dev                       never create the declaring symlink
```

`SUEDE_DEPS_URL` (default `https://suede.sh/deps`) is where it fetches `deps.sh`
for a dependency published before that script existed.

## The scripts that ship inside a dependency

[`dependency/release/core/`](../dependency/release/core/) — `deps.sh`, `diff`,
`sync`, `upstream`. They are vendored into every dependency's `release` branch,
so a consumer finds them at `<dependency>/.suede/core/`. `https://suede.sh/deps`
serves `deps.sh` from there for the installer's fallback.

## `actions/`

Scripts a GitHub Action fetches by URL and runs. They live here rather than
inside the workflow YAML so they can be tested against real local repositories
without a runner ([`actions/.tests/`](./actions/.tests/)).

### `actions/init.sh`

Everything [`initialize.yml`](../dependency/main/workflows/initialize.yml) does
to a new dependency repository, run once with `main` checked out: vendor the
maintainer's core at `.suede/core`, connect `./release` to the repo's own
`release` branch, vendor the consumer's core at `./release/.suede/core`, then
publish and push.

```bash
ORIGIN_URL=<repo> CORE_URL=<suede> bash scripts/actions/init.sh
```

It never checks out `release`. The consumer-facing core is vendored *inside*
the release folder so it reaches that branch the way all release content does —
through `main` — which is what makes `bash .suede/core/sync.sh` the whole of
updating it later.

### `actions/push-main.sh`

Pushes the current branch to `main`, replaying onto whatever landed there first
instead of failing. Used by every workflow step in this repository that writes
to `main`.

```bash
./scripts/actions/push-main.sh [BRANCH]        # BRANCH defaults to main
```

One push to `main` starts several workflows at once, more than one of them
writes back, and they check out the same commit within a second of each other —
so the one that finishes second is pushing against a tip that has moved, and git
rejects it. What these jobs add is bookkeeping (a `.gitrepo` pointer, a
generated README block) authored against a commit that has nothing to do with
whatever landed underneath, so replaying it onto the new tip is exactly right
and leaves `main` linear. A rebase *conflict* is a real disagreement rather than
a scheduling accident: it aborts and fails the job.

`PUSH_ATTEMPTS` (default 5) caps the retries so a push that can never succeed
fails rather than spinning until the runner times out.

## `create/`

### `create/dependency.sh`

Creates a dependency repository from the template, applies the settings the
template README asks for, dispatches the initialization workflow and follows it
to completion — the scripted form of [Creating a
Dependency](../README.md#creating-a-dependency). Needs an authenticated `gh`.

```bash
./scripts/create/dependency.sh <name> [public|private] [--org <org>] [--cleanup]
```

## `populate/`

### `populate/readme-after-init.sh`

Writes installation instructions to README.md by parsing the git remote origin URL.

```bash
./populate/readme-after-init.sh
```

> [!NOTE]
> Used in [initialize](../dependency/main/workflows/initialize.yml) Github Action

## Subrepo helpers

Tools for *this* repository's own subrepos (the `dependency/*` folders and the
worker under `sites/`), used by the `propagate-changes` workflow.

### `find.sh`

Finds git-subrepo directories (by locating `.gitrepo` files) in the current repository, with optional glob filtering.

```bash
./find.sh [GLOB ...]
```

### `diff.sh`

Shows diffs for the git-subrepo directories discovered via `find.sh`.

```bash
./diff.sh [--force] [TARGET ...]
```

### `pull.sh`

Runs `git subrepo pull` on each discovered subrepo to update it to its latest tracked commit.

```bash
./pull.sh [--dry-run] [TARGET ...]
```

### `push.sh`

Delegates to `pull.sh`, then runs `git subrepo push` on each discovered subrepo.

```bash
./push.sh [--dry-run] [TARGET ...]
```

### `upstream.sh`

The hosted half of a dependency's `upstream`: proposes a vendored dependency's
local changes upstream as a reviewable PR, without touching the consumed
`release` branch.

```bash
bash <(curl https://suede.sh/upstream) <path-to-dependency> [-r|--remote NAME]
```

## Migrating

[MIGRATION.md](../MIGRATION.md) moves a repository created under an earlier
suede — v1 or v2 — onto this layout.

## `curl` Flags Reference

- `-f` / `--fail` - Fail silently on HTTP errors
- `-s` / `--silent` - Silent mode
- `-S` / `--show-error` - Show errors even in silent mode
- `-L` / `--location` - Follow redirects
