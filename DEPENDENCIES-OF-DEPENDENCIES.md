# Dependencies of Dependencies

A suede dependency may itself depend on other suede dependencies. This document
is the full treatment of how that works: the three kinds a dependency can be,
the one rule that decides which, how a dependency tells its consumers what it
needs, and what the tools check. [INSTALL.md](./INSTALL.md) covers the
installer's own behaviour; this is about what the tree *means*.

## The rule

There is no manifest you write. **A dependency's kind is decided by where it
lives and what sits beside it:**

| Kind | How it is declared | What ships to consumers |
| --- | --- | --- |
| **Release** | A symlink at the root named `<name><sep><repo>` — the installer creates it — that resolves to a folder holding a `.gitrepo` outside `release/` | A record (`<entry>.gitrepo`): remote, branch, commit. Not the source |
| **Development** | Any other `.gitrepo` folder outside `release/` | Nothing. The `release` branch never hears of it |
| **Vendored release** | A `.gitrepo` folder *inside* `release/` | The source itself, verbatim |

`<name>` is the installed folder; `<repo>` is this repository's name without
the owner; `<sep>` is `.` or `__`. The name reads **what it is, then who needs it**. Suede repositories are
named `suede.<name>` (or `suede__<name>` where a period cannot appear in an
import, as in Python), and when the dependency carries that prefix your
repository's copy of it is dropped:

| Your repository | Installs | Folder | Declaring symlink |
| --- | --- | --- | --- |
| `suede.svelte-testing-utility` | `suede.typescript-testing-utility` | `suede.typescript-testing-utility/` | `suede.typescript-testing-utility.svelte-testing-utility` |
| `suede__wsfs` | `suede__sqlmodel_utils` | `suede__sqlmodel_utils/` | `suede__sqlmodel_utils__wsfs` |
| `my-app` | `widget` | `widget/` | `widget.my-app` |

A declaration is therefore just **this repository's own edge**: every edge at
the root reads `<dependency><sep><dependent>`, and the ones ending in your
repository's name (with or without its `suede.` prefix) are yours. The
separator is part of the match, only symlinks count — a real folder never
declares, whatever it is called — and the symlink must *resolve*: a dangling
one declares nothing and `extract.sh` says so. Nothing else cares how the name
was chosen; `extract.sh` publishes whatever the symlink is called.

So **promotion and demotion are a symlink**:

```bash
ln -s widget widget.my-app      # widget is now a release dependency
git rm widget.my-app            # and now it is a development dependency
```

No files move, nothing is re-fetched. What does change is what your consumers
receive, so a promotion comes with `release/` code that imports the dependency
and a demotion with the removal of those imports.

## The name is the contract

Code inside `release/` imports a release dependency as a **sibling of
`release/`**, through the declaring entry's name:

```ts
// release/index.ts, in a repository named my-app
import { helper } from "../widget.my-app/utility.ts";
```

Downstream, the contents of `release/` become a folder `my-app/` wherever the
consumer installed it, and the consumer creates `widget.my-app` **beside it**.
`../widget.my-app` therefore resolves identically on both sides, and that is
why the record a dependency publishes is named after the entry
(`widget.my-app.gitrepo`), not after the dependency.

Two things follow. A release dependency's folder and its symlink must share a
parent with `release/` — the installer refuses a release install anywhere else.
And the entry name is public API: renaming it, renaming the repository, or
changing the separator breaks every consumer's sibling path.

## What a dependency publishes

`extract.sh` writes `release/.suede/.dependencies/` from the rule:

```
release/.suede/.dependencies/
├── widget.my-app.gitrepo      remote = https://github.com/owner/widget
│                              branch = release
│                              commit = 86abeeb…
└── gadget.my-app.gitrepo
```

That is all it writes, and it removes anything else it finds there. Third-party
packages are not suede's concern — see [INSTALL.md §5](./INSTALL.md#5-third-party-packages).

Records carry the **HTTPS** remote, because whoever resolves them holds no key
of yours. Your own `.gitrepo` inside the folder keeps the SSH spelling for
pushing. Records carry no `parent`: that is a commit in *your* history and
means nothing downstream.

## How a consumer resolves them

The consumer's copy of your dependency carries your records and a `deps.sh`
that reads them. For each record it looks for `<entry>` beside your folder and
reports one of four outcomes — satisfied, reuse, decide, install — and the
commands for the last three. It recurses into what it would install, so the
whole tree is on the screen before anything runs, and it never runs anything.
The [release core README](./dependency/release/core/README.md#depssh) has the
outcomes in detail.

Three properties of that resolution are worth knowing as an author:

**Each dependency is installed once and linked from every edge.** Two of your
dependencies wanting `mixin` at the same commit get one `mixin/` folder and two
symlinks, `mixin.widget` and `mixin.gadget`. If they want it at *different*
commits, the consumer is shown the difference and chooses: link both to one copy
and own the difference, or install the second commit as `mixin-9bb0e41/` and
link to that. Both copies then ship as release dependencies of the consumer.

**Declarations say only what is true.** The recipe installs with
`--transitive`, so a dependency that is there for another dependency's edge gets
the edge (`mixin.widget`) and no declaration. Your declarations stay the list of
what *your* code imports, and your consumers' roots stay free of duplicates:
each package's edges are exactly what that package needs. A transitive install
still ships — your consumers install it from the record of the dependency that
needs it — and it is still checked at publish (below). If your own code starts
importing it, declare it: `ln -s mixin mixin.my-app`.

**A pin is a request while you work, and a requirement when you publish.** A
sibling that resolves to the right repository at another commit satisfies the
edge in the everyday recipe, so an application can run against whatever it
chooses. `deps.sh` says so plainly — "NOT the commit `mixin.widget` asks for" —
prints the `diff --at <commit>` that shows what the dependency was built
against versus what is on disk, and the two ways to line it up. A repository
that *publishes* cannot keep the mismatch: its consumers install what the
records name, so the publish guard refuses until every edge, all the way down,
resolves to exactly that commit.

## Vendored dependencies

Sometimes a pointer cannot be honest: you have changed a dependency and can
neither revert the change nor get it accepted upstream. Then the source has to
ship, and it does so by living inside `release/`:

```bash
bash <(curl -fsSL https://suede.sh/install/release) --repo owner/widget   # run inside release/
```

or, for one already installed at the root:

```bash
git mv widget release/widget
git rm widget.my-app
```

Afterwards `release/` code imports it as `./widget/...`, and your consumers get
the bytes, `.gitrepo` and all — they can still `sync` and `upstream` it
independently, which is a feature and a sharp edge.

Vendored code ships whole, so **its siblings have to ship with it**. A vendored
dependency's `mixin.widget` must resolve to something inside `release/`; a link
out to the root would reach consumers dangling. `deps.sh` places a vendored
dependency's installs inside `release/`, refuses to offer a copy from outside
it, and the publish guard fails on an escaping link.

## What the tools check

The publish guard ([`push-release.sh`](./dependency/main/core/README.md#push-releasesh))
runs two checks and refuses to publish if either fires:

| Check | Fails when | Why it matters |
| --- | --- | --- |
| `diff.sh --shipped-only` | a release dependency's files — or those of any install its edges reach, all the way down, declared or not — differ from the pinned commit | the record would point at code you did not build against; an undeclared transitive edit ships to no one |
| `deps.sh --check --in release` | an entry a record names is missing, dangling, points at a different repository, resolves to a *different commit* than the record names, or escapes `release/` from a vendored dependent — anywhere in the tree of siblings | consumers would install a tree that does not resolve, or not the tree you built against |

Between them the published tree is exactly the tested one: `diff.sh` makes
each dependency's files match its commit, and `deps.sh --check` makes each
commit match what the record above it names. A development dependency's state
is not checked: it ships nothing, and may be satisfied by anything on disk.

Two deliberate non-checks. Nothing verifies that your `release/` code actually
imports what you declare, or declares what it imports; that is what your
language's tooling is for. And nothing is checked at install time beyond the
recipe itself — the installer stages, and you look before you commit.

## Known limitations

- **Windows.** Edge entries are symlinks; work in WSL 2 with the repository on
  the Linux filesystem.
- **Case.** Two entries differing only by case are one entry on macOS and two
  on Linux CI. Nothing checks for it; do not do it.
- **Nested subrepos.** A vendored dependency carries its `.gitrepo` into your
  `release/`, and git-subrepo is awkward about subrepos inside subrepos.
  `push-release.sh` and `sync.sh` clean up the leftovers that stop a publish.
- **One record, one name.** A dependency installed twice (two commits) is two
  entries with two names, and the second one's name is what the consumer chose.
  Records point at remote and commit, so that is fine downstream, but the
  folder name is not stable across consumers.
