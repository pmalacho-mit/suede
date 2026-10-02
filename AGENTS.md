# AGENTS.md

Guidance for coding agents working in a **suede** repository — either a suede
dependency or a project that consumes one. The last section covers this
repository (the suede library itself).

You are assumed to know git, symlinks, npm and how module resolution works.
What follows is only what suede does differently, and the places where a
reasonable-looking edit is wrong.

---

## 1. What suede is

Dependency management for code **you** control, built on
[git-subrepo](https://github.com/ingydotnet/git-subrepo) instead of a registry.

A dependency's source is **vendored into the consumer's repository** — real
files, in git, editable in place — while remaining bidirectionally syncable with
the repository it came from. There is no registry, no lockfile, no
`node_modules` for these dependencies, and no build/publish step between editing
a dependency and using it.

The consequence that matters most for you: **the dependency's code in this repo
is ordinary source code.** You may read it, edit it, and commit it like any
other file. Nothing is generated or minified.

Everything suede runs is bash. The tools **print what to do and do not do it**:
the installer installs one folder and stages it; `deps.sh` prints the commands
that would resolve a dependency's own dependencies; nothing resolves a graph on
your behalf.

## 2. What a suede dependency is

A repository with **two branches** and one rule connecting them.

| Branch | Contains | Who sees it |
| --- | --- | --- |
| `main` | Everything: source, tests, examples, docs, tooling — **and a `release/` folder** | Maintainers |
| `release` | *Only* the contents of `main`'s `release/` folder | Consumers |

`release` is generated. CI (`subrepo-push-release`) syncs `main`'s `release/`
folder out to the `release` branch whenever a change under `release/` lands on
`main`. Consumers install from the `release` branch.

```
main branch                                  release branch  (generated — do not commit to it)
├── .github/workflows/         (subrepo)     ├── .github/workflows/       (subrepo)
├── .suede/core/               (subrepo)     ├── .suede/core/             (subrepo: deps.sh, diff, sync, upstream)
├── src/  tests/  docs/        (dev only)    ├── .suede/.dependencies/    (records: <entry>.gitrepo)
├── widget/                    (installed)   ├── .gitrepo
├── my-app.widget -> widget    (declares it) └── index.ts
└── release/                                 ▲
    ├── .gitrepo                             └── exactly the contents of main's release/,
    ├── .suede/core/           (subrepo)         lifted to the branch root
    ├── .suede/.dependencies/
    ├── package.json           (release/ is its own package)
    └── index.ts
```

**The single most important fact: code only reaches consumers if it is inside
`release/`.** A feature implemented in `src/` and never surfaced through
`release/` ships to nobody.

## 3. Where to put code

| The code is… | Put it in | Ships? |
| --- | --- | --- |
| The library's public surface | `release/` | Yes |
| Tests, fixtures, benchmarks | anywhere **outside** `release/` (`.tests/`, `tests/`) | No |
| Examples, demo apps, docs | outside `release/` | No |
| Build tooling, CI scripts | outside `release/` | No |
| Vendored third-party source the library must ship with | inside `release/` | Yes |

When asked to "add a feature to this library", the deliverable lives in
`release/`. Put the tests beside it — but **outside** `release/`, importing
across the boundary. Never add a test directory inside `release/`.

## 4. The three kinds of dependency, and the rule

There is no manifest you write by hand. **A dependency's kind is decided by
where it lives and what sits beside it.**

| Kind | How it is declared | What ships to consumers |
| --- | --- | --- |
| **Release** | A root entry named `<repo><sep><name>` — a symlink the installer created — resolving to a `.gitrepo` folder outside `release/` | A record (`<entry>.gitrepo`: remote, branch, commit), not the source |
| **Development** | Any other `.gitrepo` folder outside `release/` | Nothing |
| **Vendored release** | A `.gitrepo` folder **inside** `release/` | The source itself |

`<repo>` is this repository's name without the owner; `<sep>` is `.` or `__`
(`__` where a path segment must be an identifier: Python, Rust). The match
includes the separator: in a repo named `suede`, `suede-extras/` declares
nothing.

**The symlink is the whole declaration.** Delete `my-app.widget` and `widget`
is a development dependency; `ln -s widget my-app.widget` and it is a release
dependency again. No files move. Rename it to change the separator.

Code inside `release/` refers to a release dependency as a **sibling**, through
the symlink's name:

```ts
// release/index.ts, in a repo named my-app
import { helper } from "../my-app.widget/utility.ts";
```

That path is invariant across the publish boundary: downstream, `release/`'s
contents become a folder `my-app/`, and the consumer creates `my-app.widget`
beside it. **The name is the contract.** Do not "simplify" these paths, and do
not rename a root entry without updating every import of it. The installed
folder and its symlink always share a parent, and a release install anywhere
but the repository root is refused for this reason.

Because a release dependency ships as a pointer, **the pointer must be honest**:
its files must match the commit its `.gitrepo` names. CI refuses to publish
otherwise. If you modified a release dependency in place you have three honest
options: revert, upstream the change, or vendor it (`git mv widget
release/widget && git rm my-app.widget`, then repoint imports to `./widget`).
Vendored code ships whole, so what it needs beside it moves inside `release/`
too.

## 5. Dependencies of dependencies

A dependency publishes records, `release/.suede/.dependencies/<entry>.gitrepo`,
one per release dependency, named after the sibling it expects to find
**beside itself**. The consumer's copy carries them, plus `deps.sh`, which
reads them against the disk and prints, for each one:

- **satisfied** — the sibling is there and points at the right repository;
- **reuse** — missing, but the same repo is installed elsewhere at the same
  commit with no local changes: one `ln -s`;
- **decide** — missing, and what is installed differs: the `diff --at` that
  shows it, then both options (link to what you have, or install the exact
  commit under another name and link to that);
- **install** — the install command and the `ln -s`.

It recurses so the whole recipe is visible up front, numbered `[1]`, `[1.1]`,
`[2]`. It never runs anything. The installer runs it after every install.

Each install the recipe makes in a dependency repository is itself declared,
so the transitive closure ends up declared at your root; no rule demands it.
A sibling at a *different commit* than asked for satisfies the edge rather
than failing, but `deps.sh` flags it ("NOT the commit … asks for") and prints
the `diff --at <commit>` to run. Run it before moving on.

## 6. Commands

**Install** (works in any git repo; needs only `git`):

```bash
bash <(curl -fsSL https://suede.sh/install/release) --repo OWNER/REPO
```

Run it **where you want the folder**. At the root of a dependency repo it also
declares (`my-app.<name>` symlink); inside `release/` it vendors; in a plain
application it just installs. Flags: `--at <commit>`, `--branch`, `--sep`,
`--name`, `--prefix`, `--suffix`, `--dev` (never declare). It refuses to
overwrite an existing folder and names those three naming flags. It stages;
you commit.

**Inside an installed dependency** (ships with every one):

```bash
bash <dep>/.suede/core/deps.sh            # what it needs beside it, as commands
bash <dep>/.suede/core/deps.sh --check    # exit 1 if unresolved; no network
bash <dep>/.suede/core/diff               # pinned commit -> your tree: what you would propose
bash <dep>/.suede/core/diff --sync        # your tree -> release tip: what you would receive
bash <dep>/.suede/core/diff --at <commit> # against some other commit
bash <dep>/.suede/core/sync               # git subrepo pull, symlink- and cwd-safe
bash <dep>/.suede/core/upstream           # propose local edits back as a PR
```

None takes a target (`diff --in <dir>` and `deps.sh --in <dir>` are the one
exception, for tooling). An installed `.gitrepo` records the SSH remote for
`upstream`; `diff`, `deps.sh` and `sync` fall back to HTTPS when SSH does not
answer, so do not rewrite a `.gitrepo` remote to make CI work. `diff` exits `0` no difference, `1` difference, `2`
could not run. `sync` and `upstream` need git-subrepo; the others need only
`git`.

**On a dependency's `main`** (vendored at `.suede/core`):

```bash
bash .suede/core/list.sh                  # every dependency: kind, entry, path, pin
bash .suede/core/extract.sh               # regenerate release/.suede/.dependencies/
bash .suede/core/diff.sh                  # release deps that drifted from their pin
bash release/.suede/core/deps.sh --check --in release   # everything declared is in place
bash .suede/core/sync.sh                  # update every suede subrepo this repo vendors
DRY_RUN=1 bash .suede/core/push-release.sh   # the publish guard, without publishing
```

`sync.sh` is how the vendored machinery is updated, never by editing it; it
repairs the `parent` problems template-created repos have and clears the
leftovers that block the next publish.

## 7. Task recipes

**Add a dependency.** Run the install one-liner at the repo root. Read the
recipe it prints, run those commands, re-run `<dep>/.suede/core/deps.sh` until
it says everything is in place, review `git status`, commit. Add `--dev` when
only tests or examples will import it. Do not hand-clone a repo and hand-write
a `.gitrepo`.

**Update a dependency.** Preview with `bash <dep>/.suede/core/diff --sync`,
then `bash <dep>/.suede/core/sync`. The working tree must be clean first.
Never `git subrepo pull` a symlink path; that is why `sync` exists.

**Modify a dependency you consume.** Edit the files in place and commit — that
is the design. Review with `bash <dep>/.suede/core/diff` (the `+` lines are
yours). To offer it back, commit first, then `bash <dep>/.suede/core/upstream`.
That opens a PR against the dependency's `main`; **the `release` branch is
never modified**. Do not `git subrepo push` a dependency's release branch.

**Publish a change to a dependency you maintain.** Commit to `main` with the
change under `release/`. CI regenerates the records, runs the guard (`diff.sh`
plus `deps.sh --check`), and syncs `release/` to the `release` branch. If the
guard fires, `release` is untouched and the reason is in the job summary.
Nothing under `release/.suede/.dependencies/` is edited by hand.

**Promote or demote.** `ln -s widget my-app.widget` / `git rm my-app.widget`,
then update `release/` imports and run `extract.sh`.

**Remove a dependency.** `git rm -r <name>` and its symlink; `deps.sh` on
anything that pointed at it reports the dangling edge.

## 8. Third-party packages (npm and PyPI)

Not suede's concern. `release/` is a package: give it its own `package.json`
(or `pyproject.toml`) naming what its code imports, list `release` in the
repository's root `package.json` `workspaces`, and have consumers list each
installed dependency folder in theirs. One `npm install` at the root resolves
everything. Suede never edits `package.json`, `requirements.txt` or a lockfile.

## 9. Rules

Never:

- Commit to the `release` branch, or edit anything under
  `release/.suede/.dependencies/` by hand — both are generated.
- Put tests, examples or docs inside `release/`.
- Hand-edit a `.gitrepo` file, or hand-write one to fake an install.
- Edit files inside a vendored subrepo you should be *pulling* instead
  (`.suede/core/`, `release/.suede/core/`, `.github/workflows/` in a
  dependency) — the fix belongs in the suede library; `sync.sh` brings it.
- Check out the `release` branch to change something on it.
- `git subrepo pull` a symlink path, or run any subrepo command on a dirty tree.
- `git subrepo push` onto a dependency's `release` branch; use `upstream`.
- Rename a root entry, the repository, or the separator casually — every
  import and every downstream consumer keys on those names.
- Move a declaring symlink away from the folder it points at.
- Add a dependency by cloning it manually.

Always:

- Run `bash <dep>/.suede/core/deps.sh` after an install until it reports
  everything in place, and `bash .suede/core/diff.sh` before expecting a publish
  to succeed.
- Commit after installing, before syncing.

## 10. This repository (the suede library)

If you are working in `pmalacho-mit/suede` itself:

- [`scripts/install/release.sh`](./scripts/install/release.sh) is the whole
  installer: one bash script, written for **bash 3.2** (macOS) — no
  `declare -A`, `mapfile`, `${var,,}`, `readlink -f`. The same constraint
  applies to everything in `dependency/release/core/`, which ships to
  consumers.
- [`dependency/`](./dependency/) holds the parts that get vendored into a
  dependency, as subrepos: `main/core` and `release/core` (the `.suede/core`
  halves), `*/workflows` (the canonical home for the GitHub Actions), and
  `*/template`. **Tests go beside a subrepo, never inside one** — everything in
  a folder with a `.gitrepo` ships. Edit workflow files in
  `dependency/<branch>/workflows`, never in `template/.github/workflows`. Every
  shipped script must be named in its folder's README (`shipped-content.sh`
  enforces it).
- Tests: `.tests/run.sh` (Docker, hermetic) or `bash .tests/harness/run-all.sh`
  if your shell has git-subrepo. Fixtures are real local bare repositories
  built by `.tests/harness/with-suede-graph.sh`; there are no mocks of the
  record format. Each test function runs in its own subshell.
- Documentation split: [`README.md`](./README.md) is for humans adopting suede,
  [`DEPENDENCIES-OF-DEPENDENCIES.md`](./DEPENDENCIES-OF-DEPENDENCIES.md) is the
  full treatment of the classification rule and its rationale,
  [`INSTALL.md`](./INSTALL.md) is the installer's behaviour and flags, and
  [`MIGRATION.md`](./MIGRATION.md) moves v1 and v2 repositories onto this
  layout. Keep migration material out of everything except that document.
