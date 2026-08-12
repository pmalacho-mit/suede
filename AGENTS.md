# AGENTS.md

Guidance for coding agents working in a **suede** repository — either a suede
dependency or a project that consumes one. The last section covers this
repository (the suede library itself).

You are assumed to know git, symlinks, npm/PyPI and how module resolution
works. What follows is only what suede does differently, and the places where a
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
├── .suede/                                  ├── .suede/core/             (subrepo: consumer tools)
│   ├── core/                  (subrepo)     ├── .suede/.dependencies/    (the published manifest)
│   └── .dependencies/separator              ├── .gitrepo
├── src/  tests/  docs/        (dev only)    └── index.ts
└── release/                                 ▲
    ├── .gitrepo                             └── exactly the contents of main's release/,
    ├── .suede/.dependencies/                    lifted to the branch root
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

In a **consumer** repo there is no `release/` unless that repo is also a
dependency. Installed dependencies are folders at the repo root.

## 4. The naming rule

There is no manifest you write by hand. **A dependency's kind is determined by
where it lives and what it is named.**

- `$repo` — this repository's name, without the owner (e.g. `sweater-vest-suede`).
- `$SEP` — the separator, `.` or `__`. Resolution order: `--separator` flag →
  `.suede/.dependencies/separator` (a one-line file at the repo root) → majority
  of existing entries → inference from tracked file extensions → `.`.
  **Python and Rust repos use `__`** (`import app.dep` would parse as a
  submodule); path-literal languages (TS/JS/Svelte/Go/CSS/shell) use `.`.

A root-level entry named **`$repo$SEP<dependency>`** — a real folder, or a
symlink to one outside `release/` — declares a **release dependency**. The
prefix match includes the separator: in a repo named `suede`, a folder
`suede-extras/` is *not* a match.

Code inside `release/` refers to a release dependency as a **sibling**:

```ts
// release/index.ts, in a repo named consumer-lib
import { helper } from "../consumer-lib.some-dep/utility.ts";
```

That path is invariant across the publish boundary. Downstream, `release/`'s
contents become a folder named `consumer-lib/`, and the consumer's installer
recreates `consumer-lib.some-dep` next to it — so `../consumer-lib.some-dep`
resolves identically on both sides. **The name is the contract.** Do not
"simplify" these paths, and do not rename a root entry without also updating
every import of it.

## 5. The three kinds of dependency

| Kind | How it is declared | What ships to consumers |
| --- | --- | --- |
| **Release** | Root entry named `$repo$SEP<name>`, backing folder outside `release/` | A `.gitrepo` **pointer**, not the source |
| **Development** | Any other `.gitrepo` folder outside `release/` | Nothing |
| **Vendored release** | Lives **inside** `release/` | The source itself, verbatim |

Classification is checked in that order: inside `release/` wins first, then the
prefixed root entry, then everything else is development.

Because a release dependency ships as a pointer, **the pointer must be honest**:
its local files must match the commit its `.gitrepo` names. CI refuses to
publish otherwise. If you modified a release dependency in place you have
exactly three honest options — revert, upstream the change, or vendor the
dependency (`.suede/core/vendor.sh`, which moves it inside `release/` so the
source actually ships).

**A project declares its entire transitive closure at its own root.** If you
install `B` and `B` needs `C`, you get root entries for both, and `B`'s edge is
a symlink:

```
app.B/        real folder — B's release bytes
app.C/        real folder — C's release bytes
B.C     ->    ./app.C     symlink satisfying B's edge
```

The manifest is a closure, not an import list. It will list dependencies your
own code never imports. That is intentional; do not "clean it up".

## 6. Commands

All of it is one dependency-free Python 3.9 file. Inside a **dependency** (on
`main`) it is vendored, so run it from the repo root as:

```bash
bash .suede/core/suede list          # every dependency: kind, entry, path, pin
bash .suede/core/suede check         # audit the tree (see §9)
bash .suede/core/suede diff          # release deps that drifted from their pin
bash .suede/core/suede extract       # regenerate release/.suede/.dependencies/
bash .suede/core/suede remove <entry>  # drop an entry; reports orphans, deletes nothing
```

A plain **consumer** repository has no `.suede/core` — that half is vendored
only onto a dependency's `main`. Reach the same file directly instead
(substitute `bash .suede/core/suede` → this in every command below):

```bash
python3 <(curl -fsSL https://suede.sh/suede) check
```

Install a dependency (works in any git repo, no suede install required):

```bash
bash <(curl -fsSL https://suede.sh/install/release) --repo OWNER/REPO
```

Useful install flags: `--dry-run`, `--plan-json`, `--yes` (skip the prompt —
**use this in non-interactive runs**), `--commit`, `--name`, `--target`,
`--on-conflict coexist|unify-newest|defer`, `--allow-conflicting-packages`,
`--no-npm`, `--no-python`.

Sync and contribute back (these live on the release side and ship inside every
installed dependency):

```bash
bash <dep>/.suede/core/diff        # pinned commit -> your tree: what you would propose
bash <dep>/.suede/core/diff --sync # your tree -> release tip: what you would receive
bash <dep>/.suede/core/sync        # git subrepo pull, symlink- and cwd-safe
bash <dep>/.suede/core/upstream    # propose local edits back as a PR
```

None of them takes a target: each acts on the dependency it lives inside. Extra
arguments are forwarded — to `git subrepo pull` for `sync`, to `git diff` for
`diff` — so `sync --force` and `diff --stat` work. If `git subrepo` is not on
`PATH` but `GIT_SUBREPO_ROOT` is set, `sync` and `upstream` source
`$GIT_SUBREPO_ROOT/.rc` before giving up; `diff` needs only `git`.

`diff` is how you inspect a dependency you have edited: its history is not in
this repository, so `git log` on that folder has nothing to compare against.
It reads your files as they are on disk (uncommitted edits and new files in,
`.gitignore`d files and `.gitrepo` out) and exits `0` for no difference, `1`
for a difference, `2` if it could not run at all.

Maintainer tools on `main`: `.suede/core/diff.sh`, `.suede/core/vendor.sh`, and
`.suede/core/push-release.sh` (what CI runs; `DRY_RUN=1` stops after the guard).

## 7. Task recipes

**Add a dependency.** Run the install one-liner with `--yes`. It resolves the
whole closure, installs each dependency once flat at the root, creates the edge
symlinks, and **stages without committing**. Review, then commit. Do not
hand-clone a repo and hand-write a `.gitrepo`.

**Update a dependency.** Preview it with `bash <dep>/.suede/core/diff --sync`,
then `bash <dep>/.suede/core/sync`. The working tree must be clean before the
sync — `git subrepo pull` refuses a dirty tree even though install does not.
Never run `git subrepo pull` on a symlink path; it fails outright, which is why
`sync` exists.

**Modify a dependency you consume.** Edit the files in place and commit — that
is the design. The change lives in your repo's history. Review it with
`bash <dep>/.suede/core/diff` (the `+` lines are yours). To offer it back to the
library, commit first, then `bash <dep>/.suede/core/upstream`. That splits your
commits onto a `downstream/**` branch on the dependency's remote and opens a PR
against its `main`. **The `release` branch is never modified**, so other
consumers are unaffected.

**Do not `git subrepo push` a dependency's release branch.** It writes unvetted
code straight onto the branch every consumer installs from. `upstream` is the
supported path.

**Publish a change to a dependency you maintain.** Commit to `main` with the
change under `release/`. CI regenerates the manifest, runs the guard
(`suede diff` + `suede check`), and syncs `release/` to the `release` branch. If
the guard fires, the `release` branch is left untouched and the reason is in the
job summary. Nothing about `release` is edited by hand — including
`release/.suede/.dependencies/`, which is generated.

**Promote a development dependency to a release dependency.** Rename its root
entry to `$repo$SEP<name>` (or add a symlink with that name), update the
`release/` imports, then run `check`. Demotion is the same rename in reverse.

## 8. Third-party packages (npm and PyPI)

A dependency publishes its own third-party needs as
`release/.suede/.dependencies/package.json` and `.../requirements.txt`
(generated by `extract` from the repo's root `package.json` / `requirements.txt`).
On install these are merged into the consumer's files: missing packages are
added, **lockfiles are never touched**, and `requirements.txt` is appended to
rather than rewritten.

A package the consumer **already declares at a different version** blocks the
install rather than being resolved silently:

```
BLOCKED

  python dependency sqlmodel: a dependency asks for sqlmodel>=0.0.14, your
  requirements.txt declares sqlmodel==0.0.9.
  Unify the versions yourself - suede will not guess - or re-run with
  --allow-conflicting-packages to keep your own declarations and install the
  rest anyway.
```

Re-run with `--allow-conflicting-packages` to install anyway: the consumer's
declarations are kept verbatim, non-conflicting packages still merge, and each
conflict is reported as a warning. Choosing that over unifying the range is a
judgment call about the consumer's code — surface it, do not make it silently.

Two *dependencies* disagreeing with each other never blocks; the first in pin
order wins and the rest are warnings.

## 9. Reading `check`

`check` enforces exactly one structural rule — that nothing was resolved
implicitly — and stays informational about *which* commit you chose.

| Code | Level | Meaning |
| --- | --- | --- |
| `missing-edge` | FAIL | A dependency expects a sibling that is absent or dangling. Install it, or declare your own resolution at the root. |
| `undeclared-edge` | FAIL | An edge resolves to a folder no root entry declares. That is an implicit dependency — give it a root entry. |
| `dangling-entry` | WARN | An entry named like a release dependency that does not resolve or has no `.gitrepo`. Unfinished install or leftover. |
| `case-collision` | WARN | Entries differing only by case. One entry on macOS, two on Linux CI. |
| `remote-differs`, `pin-differs` | INFO | You resolved a dependency differently than it asked for. Legitimate — you took ownership. Never a failure. |

Exit codes, for scripting: `0` success, `2` usage, `3` precondition (includes a
blocked package merge), `4` unresolved conflict, `5` `check` found a FAIL.

## 10. Rules

Never:

- Commit to the `release` branch, or edit anything under `release/.suede/.dependencies/` by hand — both are generated.
- Put tests, examples or docs inside `release/`.
- Hand-edit a `.gitrepo` file, or hand-write one to fake an install.
- Edit files inside a vendored subrepo you should be *pulling* instead (`.suede/core/`, `.github/workflows/` in a dependency) — the fix belongs in the suede library.
- `git subrepo pull` a symlink path, or run any subrepo command on a dirty tree.
- `git subrepo push` onto a dependency's `release` branch; use `upstream`.
- Rename a root entry, the repository, or the separator casually — every import and every downstream consumer keys on those names.
- Add a dependency by cloning it manually. Use the installer so the closure, the manifest and the edge symlinks stay consistent.

Always:

- Run `bash .suede/core/suede check` after anything that touches entries, symlinks or installs.
- Run `bash .suede/core/suede diff` before expecting a publish to succeed.
- Pass `--yes` when installing non-interactively; the installer otherwise waits at a prompt.
- Commit after installing, before syncing.

## 11. This repository (the suede library)

If you are working in `pmalacho-mit/suede` itself:

- [`scripts/suede.py`](./scripts/suede.py) is the whole installer — one
  dependency-free Python 3.9 file. It is written to be read and patched by a
  stranger on an unfamiliar system: plain functions and dataclasses, no
  metaclasses, no decorator machinery, no `match` statements. Sections run in a
  strict dependency direction, and **every call to git is confined to section
  4** — `plan()`, `check()` and `announce()` are pure over the model, which is
  what makes the test suite literals instead of fixtures. A test asserts that
  boundary; do not cross it.
- Tests: `python3 -m unittest discover .tests/unit -t .tests/unit` and the same
  for `.tests/integration`. The full suite (including shell tests) is
  `.tests/run.sh`, which runs in Docker. Type-check with
  `npx basedpyright scripts/suede.py` — the config is strict and the file is
  expected to be clean.
- [`dependency/`](./dependency/) holds the parts that get vendored into a
  dependency, as subrepos: `main/core` and `release/core` (the `.suede/core`
  halves), `*/workflows` (the canonical home for the GitHub Actions), and
  `*/template`. **Tests go beside a subrepo, never inside one** — everything in
  a folder with a `.gitrepo` ships. Edit workflow files in
  `dependency/<branch>/workflows`, never in `template/.github/workflows`.
- Documentation split: [`README.md`](./README.md) is for humans adopting suede,
  [`DEPENDENCIES-OF-DEPENDENCIES.md`](./DEPENDENCIES-OF-DEPENDENCIES.md) is the
  full treatment of the classification rules and their rationale,
  [`INSTALL.md`](./INSTALL.md) is the install algorithm and CLI surface, and
  [`MIGRATION-V1-V2.md`](./MIGRATION-V1-V2.md) covers moving a v1 repository
  onto v2. Keep v1 material out of everything except the migration document.
