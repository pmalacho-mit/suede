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
| **Release** | A root entry named `<repo><sep><name>` — by convention a symlink the installer created — that resolves to a folder holding a `.gitrepo` outside `release/` | A record (`<entry>.gitrepo`): remote, branch, commit. Not the source |
| **Development** | Any other `.gitrepo` folder outside `release/` | Nothing. The `release` branch never hears of it |
| **Vendored release** | A `.gitrepo` folder *inside* `release/` | The source itself, verbatim |

`<repo>` is this repository's name without the owner; `<sep>` is `.` or `__`.
The match includes the separator — in a repository named `suede`, a folder
`suede-extras/` is not a declaration — and the entry must *resolve*: a dangling
symlink declares nothing and `extract` says so.

So **promotion and demotion are a symlink**:

```bash
ln -s widget my-app.widget      # widget is now a release dependency
git rm my-app.widget            # and now it is a development dependency
```

No files move, nothing is re-fetched. What does change is what your consumers
receive, so a promotion comes with `release/` code that imports the dependency
and a demotion with the removal of those imports.

## The name is the contract

Code inside `release/` imports a release dependency as a **sibling of
`release/`**, through the declaring entry's name:

```ts
// release/index.ts, in a repository named my-app
import { helper } from "../my-app.widget/utility.ts";
```

Downstream, the contents of `release/` become a folder `my-app/` wherever the
consumer installed it, and the consumer creates `my-app.widget` **beside it**.
`../my-app.widget` therefore resolves identically on both sides, and that is
why the record a dependency publishes is named after the entry
(`my-app.widget.gitrepo`), not after the dependency.

Two things follow. A release dependency's folder and its symlink must share a
parent with `release/` — the installer refuses a release install anywhere else.
And the entry name is public API: renaming it, renaming the repository, or
changing the separator breaks every consumer's sibling path.

## What a dependency publishes

`extract.sh` writes `release/.suede/.dependencies/` from the rule:

```
release/.suede/.dependencies/
├── my-app.widget.gitrepo      remote = https://github.com/owner/widget
│                              branch = release
│                              commit = 86abeeb…
└── my-app.gadget.gitrepo
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
symlinks, `widget.mixin` and `gadget.mixin`. If they want it at *different*
commits, the consumer is shown the difference and chooses: link both to one copy
and own the difference, or install the second commit as `mixin-9bb0e41/` and
link to that. Both copies then ship as release dependencies of the consumer.

**The consumer's closure declares itself.** Every install the recipe makes in a
dependency repository is declared (`<repo><sep><name>`) by the installer, so the
transitive dependencies end up in the consumer's own records with no separate
rule. Deleting one of those symlinks is allowed — the consumer's consumers will
then resolve that dependency from *your* record instead of theirs.

**A pin is a request, not a lock.** A sibling that resolves to the right
repository at another commit satisfies the edge. `deps.sh` says so plainly —
"NOT the commit `widget.mixin` asks for" — and prints the `diff --at <commit>`
that shows what the dependency was built against versus what is on disk, so the
consumer owns the resolution knowingly rather than by accident.

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
git rm my-app.widget
```

Afterwards `release/` code imports it as `./widget/...`, and your consumers get
the bytes, `.gitrepo` and all — they can still `sync` and `upstream` it
independently, which is a feature and a sharp edge.

Vendored code ships whole, so **its siblings have to ship with it**. A vendored
dependency's `widget.mixin` must resolve to something inside `release/`; a link
out to the root would reach consumers dangling. `deps.sh` places a vendored
dependency's installs inside `release/`, refuses to offer a copy from outside
it, and the publish guard fails on an escaping link.

## What the tools check

The publish guard ([`push-release.sh`](./dependency/main/core/README.md#push-releasesh))
runs two checks and refuses to publish if either fires:

| Check | Fails when | Why it matters |
| --- | --- | --- |
| `diff.sh` | a release dependency's files differ from its pinned commit | the record would point at code you did not build against |
| `deps.sh --check --in release` | an entry a record names is missing, dangling, points at a different repository, or escapes `release/` from a vendored dependent — anywhere in the tree of siblings | consumers would install a tree that does not resolve |

A sibling at a *different commit* than asked for is not a failure in either
check. Neither is a development dependency's state: it ships nothing, and may
be satisfied by anything on disk.

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
