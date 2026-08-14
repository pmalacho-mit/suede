# Dependencies of Dependencies — The 3 Types

This concerns the cases where a [suede](https://github.com/pmalacho-mit/suede) dependency, call it _some-lib_, relies on the source code of one or more other suede dependencies — either in _some-lib_'s shipped `release/` code, or only in the development of _some-lib_ on its `main` branch (e.g. for testing, examples, or docs).

The whole idea is that **the kind of a dependency is fully determined by where it lives on `main` and what it is named.** No config file, no manifest, no language-specific tooling. Just folders and names.

Here are the three kinds of dependencies:

- **Release Dependency** — announced by a **root-level entry named `$repo$SEP$dependency`**: either a real folder with that name, or a symlink with that name pointing to a folder elsewhere outside `release/`. The backing folder contains a `.gitrepo` file. Your `release/` code references it (via its full name, e.g. `import {} from "$repo.$dependency"`, `from $repo__$dependency import *`), but you do **not** ship its source; you ship a pointer to its remote commit.
- **Development Dependency** — any suede dependency (a `.gitrepo`-containing folder) outside `release/` that has **no** qualifying prefix-named root entry. The `release` branch knows nothing about it.
- **Vendored Release Dependency** — lives _inside_ `release/`. It ships verbatim with your `release` branch like any other release file.

The goal is the most _boring_ (but still ergonomic) solution. Folders and names — _chef's kiss_.

Each kind has a flag on `install`, because "where do the bytes land" and "what is this" are the same question:

```bash
bash <(curl -fsSL https://suede.sh/install/release) --repo owner/name            # release
bash <(curl -fsSL https://suede.sh/install/release) --repo owner/name --dev      # development
bash <(curl -fsSL https://suede.sh/install/release) --repo owner/name --vendor   # vendored
```

> **Note**
> `$repo`: the name of the repository, without the `owner/` prefix.
> `$SEP`: the separator between `$repo` and the dependency name. See [Separators](#separators).

---

## The classification rule

The three types are mutually exclusive and exhaustive. Dependencies are resolved by walking this in order:

1. Is the dependency's folder **inside `release/`**? → **Vendored Release Dependency.** (Stop. Names are irrelevant here.)
2. Otherwise, is there an entry **at the project root** (same level as `release/`) whose name is **`$repo` followed by a legal separator**, and whose backing folder — the entry itself if it's a folder, or the symlink's target otherwise — sits **outside `release/`** and contains a `.gitrepo`? → **Release Dependency.**
3. Otherwise → **Development Dependency.**

> **Important**
> **The prefix match includes the separator.** An earlier draft of this rule said "name begins with `$repo`", which misfires: in a repo named `suede`, a sibling folder `suede-extras/` begins with `suede` and would be silently promoted to a release dependency. The name must be `$repo` followed by one of the legal separators (`.` or `__`, plus whatever `.suede/.dependencies/separator` declares).

> **Note**
> `extract/dependencies.sh` only ever treats backing folders **outside** `release/` as candidates. So a stray prefix-named symlink pointing _into_ `release/` can never be misread as a release dependency — step 1 already owns everything inside `release/`. This is what keeps the rule robust against leftover links after a [vendor](#vendor).

---

## No indirect dependencies

**A project records every dependency in its transitive closure as a release dependency of its own.**

If `app` installs `B`, and `B`'s manifest names `C`, then after install `app` has root entries for _both_:

```
app.B/            ← real folder (B's release-branch bytes)
app.C/            ← real folder (C's release-branch bytes)
B.C               → symlink to ./app.C          (satisfies B's edge)
```

and `app`'s own `release/.suede/.dependencies/` contains `app.B.gitrepo` **and** `app.C.gitrepo`.

Three things fall out of this, and they are the reason the bookkeeping is worth it:

1. **A manifest is a complete recipe.** A consumer reads `.suede/.dependencies/`, installs each pointer once, flat, and is done. No recursion, no resolution algorithm, no solver.
2. **Recursion becomes a repair path, not the happy path.** The installer still _reads_ dependency manifests — it must, in order to know which edge entries to create — but under a well-formed tree it never discovers a pin it wasn't already told about. A pin that appears only in a dependency's manifest is precisely the CI failure condition.
3. **Resolution authority sits with the consumer.** Every dependency in the closure is named in _their_ root, so every one is theirs to repoint, fork, unify, or override.

The cost: `app`'s manifest advertises dependencies `app`'s own code never imports. That is intentional. **The manifest is a closure, not an import list.**

### The ownership rule

> **The root owns the bytes. Dependents get links.**

For every distinct dependency in the closure:

- Exactly **one real install**, named `$repo$SEP<name>`, at the repo root.
- Every dependent edge `<dependent>$SEP<name>` is a **relative symlink** to that install.

The reverse arrangement (the dependent owns the folder, the root gets a symlink) was considered and rejected. Removing `B` would delete the folder `app.C` points into, even though `app` still declares `C`. The name that ships in the manifest should be backed by the bytes, not by an indirection into a folder named after a different project. Symlink counts are identical either way, so there is no cost to the safe arrangement.

---

## Separators

An entry named `X$SEP Y` is read by **`X`'s source code** — `X`'s imports contain the literal string `../X$SEP Y`. So **the separator belongs to the dependent**, not to the installer and not to the dependency.

This has one large consequence: **the separator is never inferred for a dependency-scoped entry.** When `app` installs `B` and must create `B`'s edge to `C`, the required entry name is already fixed by `B`'s authors and is recorded verbatim as the manifest filename. Read `B/.suede/.dependencies/` and use the basename exactly:

```
B/.suede/.dependencies/B__C.gitrepo   →  create an entry named exactly `B__C`
```

Inference and `--separator` govern **only the project's own entries** (`$repo$SEP…`), because the project's author is the one writing those imports.

**Never split a manifest filename.** Don't try to parse `B__C.gitrepo` into `(B, __, C)` — you'd have to guess where the separator ends. The two facts you need come from two unambiguous places:

| You need | Read it from |
| --- | --- |
| The dependent's required entry name | The manifest **filename**, verbatim |
| The dependency's own name (to build `$repo$SEP<name>`) | The **`remote`** field inside the `.gitrepo`, basename, `.git` stripped |

### Choosing `$SEP` for your own project

Precedence:

1. `--separator <str>` flag
2. `.suede/.dependencies/separator` — a one-line file at the **project root** (not inside `release/`)
3. Majority of existing `$repo$SEP*` root entries
4. Extension inference over `git ls-files` (tracked files only, so `.gitignore` is respected for free)
5. Default `.`

Whatever is resolved is written to `.suede/.dependencies/separator` so later installs are deterministic.

> **Important**
> The separator file **must never be copied into `release/`.** A consumer's separator is their own choice and has nothing to do with yours. Shipping it would imply otherwise. It also means `extract` never has to worry about it — the file lives outside `release/`, and everything that consumes the manifest globs `*.gitrepo`, so a bare `separator` file is inert.

| Extensions | `$SEP` | Why |
| --- | --- | --- |
| `ts tsx js jsx mjs cjs svelte vue css scss go` | `.` | The import specifier is a literal path string; dots are legal |
| `py pyi` | `__` | A dot is unrepresentable — `import app.dep` parses as package `app`, submodule `dep` |
| `rs` `rb` | `__` | Path segments surface as module identifiers |
| `sh c h cpp hpp` | `.` | Literal paths |
| _none / tie / unknown_ | `.` | Default |

The rule underneath the table: **`$SEP` must be legal inside a module identifier in the importing language.** `.` works wherever the import is a path literal; `__` is required wherever a path segment must be an identifier.

---

## Release Dependency

The most involved case. A release dependency is a suede dependency that your **published** code depends on (code in your `release/` folder references it), but which your dependency will **not** ship directly. Its source appears nowhere on the `release` branch consumed by others — only a `.gitrepo` pointer to it does.

**Why a pointer and not the code?** The `release` branch ships `release/.suede/.dependencies/<entry-name>.gitrepo`, which records the dependency's remote URL and the exact `release`-branch commit you built against. A downstream consumer resolves that pointer themselves. This is the feature: the consumer opts in explicitly, can install the exact pinned version, or can substitute their own resolution — all without touching your code.

**The catch that falls out of this:** because you ship a pointer rather than the bytes, the pointer has to be honest. If your local copy of the dependency has been modified beyond the commit named in its `.gitrepo`, then what you built and tested against is **not** what a downstream consumer should resolve.

> **Important**
> Release dependencies must **not** contain local modifications relative to their remote commit. This is enforced by the [`diff`](#diff) check, wired into [subrepo-push-release](#supporting-actions): a divergent release dependency fails the push to `release` (the `.gitrepo` file itself is excluded, since it's local metadata). If the changes can't be (1) reverted or (2) [upstreamed](#modifying-ie-pushing), convert the dependency to a [Vendored Release Dependency](#vendored-release-dependency) with the [`vendor`](#vendor) script so the code actually ships.
>
> This is a different thing from your pin differing from what a dependency asked for. See [What the checks do and don't enforce](#what-the-checks-do-and-dont-enforce).

### Layout on `main`

A release dependency can take **either of two equivalent forms** — the classification rule doesn't care which:

**Form A — plain folder (direct).** The subrepo simply _is_ the prefix-named root folder:

```
$repo.some-suede-dependency/
  .gitrepo
  utility.ts
release/
  index.ts                         →  imports ../$repo.some-suede-dependency
```

**Form B — symlink (indirect).** The real subrepo lives **anywhere the author chooses** and a prefix-named root symlink points at it:

```
deps/                              (or any location you like)
  some-suede-dependency/
    .gitrepo
    utility.ts
$repo.some-suede-dependency        →  symlink to deps/some-suede-dependency
release/
  index.ts                         →  imports ../$repo.some-suede-dependency
```

Either way, `release/` code imports through the same `../$repo.some-suede-dependency` path — the **name** is what's load-bearing, not the entry's type.

The `$repo$SEP` prefix is **required** for classification, but the suffix is free — which lets one project reference multiple versions of the same suede dependency, each installed separately with its own uniquely named entry (e.g. `$repo.some-dep` and `$repo.some-dep-1a2b3c4`).

> **Warning**
> **Form B downstream is a use-at-your-own-risk feature.** On `main` it is entirely safe: you control both the file layout and your own imports. Downstream it is not, because the installer is placing a _dependency's_ edges and cannot know how that dependency's toolchain resolves `../` through a symlink.
>
> Concretely: install _sweater-vest_ at `deps/sweater-vest` with a root symlink `app.sweater-vest` pointing at it. _sweater-vest_'s code says `import "../sweater-vest.dockview"`. Node dereferences to the realpath by default, so `../` is `deps/`. A bundler configured with `preserveSymlinks` keeps the link path, so `../` is the repo root. The two answers need the edge entry in two different places.
>
> The installer's default is **flat at the repo root**, where the real path and the entry path coincide and the question disappears. `--target` is supported for consumers who want shared or out-of-tree installs; when it is used, the installer creates the edge entry in **both** locations (both are symlinks, so the cost is negligible) and prints a warning naming the toolchains known to differ. If your build resolves neither location, you own the fix.

### Example

Assume the layout above lives in a repo called _consumer-lib_. Its `release/index.ts` references the dependency through the prefix-named entry:

```ts
// release/index.ts
import { helper } from "../consumer-lib.some-suede-dependency/utility.ts";

helper();
```

The author has declared: "I expect to find _some-suede-dependency_ at `../consumer-lib.some-suede-dependency` — i.e. as a sibling of my folder." `extract/dependencies.sh` finds the root entry, resolves its backing folder, confirms the folder sits outside `release/` and has a `.gitrepo`, and writes that `.gitrepo` to `release/.suede/.dependencies/consumer-lib.some-suede-dependency.gitrepo`. The dependency's _source_ never enters `release/`.

A downstream repo that installs _consumer-lib_ receives the pointer, and resolves it as a sibling:

```
consumer-lib/
  .gitrepo
  .suede/.dependencies/consumer-lib.some-suede-dependency.gitrepo
  index.ts                                     →  imports ../consumer-lib.some-suede-dependency
consumer-lib.some-suede-dependency             →  symlink to ./app.some-suede-dependency
app.some-suede-dependency/                     ←  the bytes, declared by the consumer
  .gitrepo
  utility.ts
```

> **Note**
> The contract is: **a sibling named `$repo$SEP$dependency` exists next to the installed `$repo/` folder and either _is_, or points to, a folder containing the depended-upon code.** Note the symmetry — this downstream contract is exactly the same rule that classified the dependency upstream. A release dependency looks the same on both sides of the publish boundary.

What's powerful is that the consumer can also resolve the dependency **another way** — their own implementation, a fork, a patched build — with zero change to _consumer-lib_'s code. They simply back the prefix-named sibling with something else, and declare it in their own root. They of course now own the responsibility of making it work.

### Install-script resolution

The install script materializes a pointer by downloading the release-branch tree (no git history) and hand-writing the `.gitrepo`. `git subrepo` is **not** used to install — only afterwards, for [`pull` and `push`](#upgrading-ie-pulling). See [The install/git-subrepo contract](#the-installgit-subrepo-contract) for the invariants this depends on.

**Layout:** flat at the repo root by default. Every install and every entry is a root-level sibling. `--target <path>` relocates the real install and is documented as [use-at-your-own-risk](#layout-on-main). `--vendor` puts everything inside `release/` instead, and refuses `--target` — vendored code has to live where it ships from.

**Dedup:** before installing, the script checks whether the pointer's exact remote and commit are **already present** in the tree. If so it creates an edge symlink to the existing install rather than re-cloning. The filesystem is the lockfile — there is no state file, and every planning decision comes from scanning the working tree.

What counts as "already present" depends on the kind being installed, because it is really the question *what may this edge point at*. A release dependency's edge must land on something declared at the root, or the tree would fail its own [declaration invariant](#what-the-checks-do-and-dont-enforce). A development dependency's edge may land on anything installed, prefixed or not. A vendored dependency's edge may only land inside `release/`.

**Conflicts:** when two dependents want the same remote at different commits, the script offers three resolutions and never picks silently:

| Resolution | Result |
| --- | --- |
| **Coexist** | Two installs, `$repo$SEP C` and `$repo$SEP C-<short7>`; each edge keeps its own pin. The naming convention makes this safe — each edge is scoped by its dependent's name. ⚠ Two runtime copies: breaks singletons, `instanceof`, shared framework context. |
| **Unify** | One install; both edges point at it. ⚠ One dependent is now running against a commit it wasn't tested with. |
| **Defer** | Install nothing for the conflicting edge; print what's needed and exit non-zero. Default in non-interactive runs. |

**Overrides are announced, not challenged.** If a consumer has deliberately resolved `B`'s edge to a different remote or commit than `B`'s manifest names, the installer reports the override on the plan line and proceeds. The consumer's declared root entry wins — that is the whole point of consumer-side resolution.

---

## Development Dependency

Development dependencies are suede dependencies the `release` branch needs to know nothing about: test harnesses, fixtures, example apps, doc generators, benchmarking tools. They live anywhere outside `release/` and are **never** extracted into `release/.suede/.dependencies/`.

The definition: **any `.gitrepo`-containing folder that isn't announced by a `$repo$SEP`-prefixed root entry is a development dependency.** Three natural ways a dependency stays "development":

1. **No root entry at all** — keep it wherever it lives (e.g. `tools/test-helpers/`) and reference it by its real path from your dev/test code. Simplest.
2. **Nested anywhere below the root** — `extract` only scans the project root, so a `.gitrepo` folder tucked under `tests/` is invisible to it.
3. **A root entry with a non-qualifying name** — any name that isn't `$repo` + separator is skipped. If you want sibling-style import ergonomics for a dev dependency, pick a different prefix (e.g. `dev.test-helpers`) and it will never be extracted.

> **Note**
> Option 3 is also the escape hatch for "I structured this like a release dependency, but on second thought it's dev-only." Rename the root entry to drop the prefix and the classification flips — no files moved, though dev-side imports need the matching rename. The reverse promotion is equally a rename.

### Installing one

```bash
bash <(curl -fsSL https://suede.sh/install/release) --repo owner/some-suede-dependency --dev
```

`--dev` is option 1 and option 3 at once: the install lands at the repo root under its **own** name — `some-suede-dependency/`, no `$repo$SEP` prefix — so the classification rule reads it as development and `extract` never sees it. Nothing is written to `release/.suede/.dependencies/`.

**Its dependencies are not doubled as yours.** This is the difference that matters, and it follows from the same rule. A release install flattens its whole closure into your root *and your manifest*, because your consumers have to resolve every pin you depend on. A development install has no consumers to inform, so its closure lands unprefixed and unrecorded:

```
some-suede-dependency/                       ← real folder, no prefix
some-suede-dependency.its-own-dependency/    ← real folder too: the entry is the install
```

If something already on disk satisfies one of those edges — a release dependency of yours, or a dev dependency installed earlier — the edge points at it and nothing is copied:

```
app.dockview-svelte-suede/                  ← already yours, a release dependency
some-suede-dependency.dockview-svelte-suede → symlink to ./app.dockview-svelte-suede
```

Third-party packages follow the same logic: `devDependencies` and `requirements-dev.txt`, neither of which `extract` publishes.

#### The entry is the install (and `--root-owned`, when you'd rather it weren't)

Under [the ownership rule](#the-ownership-rule) a closure of five dependencies is ten root entries: five folders and five links. That rule's reason — the name that ships in a manifest must be backed by bytes, not by an indirection — does not apply to a dependency that ships no manifest, so `--dev` and `--vendor` do not pay for it. Each transitive install is named after the edge that asks for it, and the entry *is* the install:

```
sweater-vest-suede/                                        ← requested; keeps its own name
sweater-vest-suede.browser-control-container-suede/        ← real folders, named by the edge
sweater-vest-suede.dockview-svelte-suede/
sweater-vest-suede.programmatic-docker-suede/
sweater-vest-suede.typescript-cli-suede/
browser-control-container-suede.programmatic-docker-suede  → symlink to ./sweater-vest-suede.programmatic-docker-suede
```

Ten entries become six. The one link left is the one links are actually for: a *second* dependent wanting a pin the first already owns. The names are manifest filenames verbatim, so each dependent's own separator is preserved without anything being parsed — the same rule as everywhere else, used as a directory name instead of a link name. What you asked for keeps its own name, since nothing asked for it by name.

**`--root-owned` opts back into the release arrangement**: one install per pin under the dependency's own name, and an entry of its own for every edge. Worth it when you want a name that does not depend on who asked — you import a transitive dependency directly, or you expect to promote it later. It is accepted for a release install too, where it describes what already happens and changes nothing.

Neither arrangement is disturbed by a later run using the other: an install that already satisfies a pin is reused wherever it sits and under whatever name, and the naming rule only decides what a *new* install is called.

---

## Vendored Release Dependency

Vendored release dependencies ship **with** your `release` branch. Because they live _inside_ `release/`, they are ordinary release content: `subrepo-push-release` copies them to the `release` branch verbatim, source and all.

Use this when a release dependency can't stay pristine — you've made local modifications you can't revert and can't (or don't want to) upstream — so a `.gitrepo` _pointer_ would no longer describe what the code you ship actually depends on. Vendoring trades "consumer resolves it themselves" for "the code is right there, guaranteed correct." Reach for the [`vendor`](#vendor) script to do the move safely.

Things to keep in mind once a dependency is vendored:

- Its `.gitrepo` ships too, so downstream consumers end up with a **nested subrepo** inside their installed `consumer-lib/` subrepo. That's a feature (they can still `git subrepo pull/push` it independently) but also a sharp edge.
- The install script must **report** vendored dependencies it finds, even though there's nothing to install — a subrepo inside a subrepo shouldn't be a surprise discovery.
- Imports change. Code that referenced `../$repo$SEP$dependency` must be repointed at the new in-`release/` location. [`vendor`](#vendor) prints the files that need this.
- There's no longer a qualifying root entry, so the classification rule cleanly lands it in step 1.

### Installing one

```bash
bash <(curl -fsSL https://suede.sh/install/release) --repo owner/some-suede-dependency --vendor
```

The bytes land at **`release/<name>`** — the top of `release/`, beside the code that imports them, under the dependency's own name rather than a `$repo$SEP` one (the prefix announces a release dependency at the *root*, which this is not). Not somewhere under `release/.suede/`: a leading dot is unrepresentable in a Python import, so anything nested there would be reachable in some languages and not in others.

**Vendoring is transitive, and it has to be.** Vendored code ships whole, so everything it imports has to ship with it — a sibling outside `release/` would reach a consumer as a dangling link. So every pin in the closure is vendored beside it:

```
release/
  index.ts                                       →  imports ./some-suede-dependency
  some-suede-dependency/                         ←  real bytes + .gitrepo
  some-suede-dependency.its-own-dependency/      ←  real bytes + .gitrepo; the entry is the install
```

That holds **even when the same commit is already installed at your root**: `app.its-own-dependency/` does not ship, so a link to it would be broken by the time a consumer sees it. The two copies are intentional, and `check` fails on the arrangement that avoids them.

Nothing is recorded in `release/.suede/.dependencies/` — there is no pointer to record, the source is right there. Third-party packages *are* merged into your own `package.json` and `requirements.txt`, because the shipped code needs them installable by whoever receives it.

A project with no `release/` directory is refused rather than having one invented for it: with nothing to ship, vendoring means nothing. Install it as a release dependency, or with `--dev`.

To vendor a dependency you **already** installed as a release dependency, use [`vendor`](#vendor) instead — it moves the folder you have (local modifications and all, which is usually the reason you are vendoring) rather than fetching the pin afresh.

---

## The invariant (the name is the contract)

The single idea holding this together: **the parent-relative path to a release dependency is invariant across the publish boundary.**

On `main`, `release/` and the `$repo$SEP$dep` entries are siblings, and `release/` code references `../$repo$SEP$dep`. Downstream, your `release/` content becomes a folder `$repo/`, and the `$repo$SEP$dep` siblings are recreated next to it — so the very same `../$repo$SEP$dep` resolves identically. Nothing in the shipped code has to change; the consumer only has to reproduce the sibling. And because classification keys on the name rather than on any particular filesystem construct, "reproduce the sibling" means exactly one thing on both sides: _make a correctly named entry exist_.

Symlinks are not structurally special — they're an **optional convenience** that buys:

1. **Free physical placement** — the real subrepo can live anywhere the author likes while the named marker sits at the root. (Author-side only; see the note under [Layout on `main`](#layout-on-main).)
2. **Shared installs** — several edges can point at one physical copy. This is how the [ownership rule](#the-ownership-rule) works.
3. **Resolution control** — a consumer can repoint an entry at a fork, a shared install, or their own implementation without renaming anything.

---

## Implementation

The installer is a **single dependency-free Python 3.9 file**, `scripts/suede.py`. `install/release.sh` is a thin bootstrap that checks for a suitable `python3`, downloads the file, and execs it — so the documented one-liner is unchanged:

```
bash <(curl https://suede.sh/install/release) --repo <owner/name>
```

Because it is one readable file with no dependencies, a consumer who hits a problem on an unusual system can download it, open it, and patch it. That property is the reason Python was chosen over a compiled binary, and it constrains how the file may be written: plain functions and dataclasses, no metaclasses, no decorator machinery, no cleverness that would make a stranger's patch harder than it needs to be.

Python 3.9 is the floor, set by macOS Command Line Tools (pinned at 3.9.6). `match` statements are avoided entirely so the file stays parseable on older interpreters and a version guard can produce a readable error instead of a `SyntaxError`.

All network access goes through `git` (`ls-remote`, `clone --depth 1`, sparse checkout) rather than HTTP. This works with any git host, inherits the user's existing auth, avoids API rate limits, and sidesteps `tarfile` extraction-filter differences across Python patch releases. `.gitrepo` files are read and written with `git config -f`, which is what git-subrepo itself uses.

A live `.gitrepo` records the **SSH** spelling of the remote and a published manifest record the **HTTPS** one, because they answer to different people: a live pointer has to survive a bare `git subrepo push`, which needs an authenticated write, while a shipped pointer is resolved by consumers and CI runners holding no key of yours. A `Pin` canonicalizes its remote on construction so the two are one dependency rather than two, and fetching tries SSH before HTTPS so a key is enough for a private repository. See [Two spellings of one remote](./INSTALL.md#two-spellings-of-one-remote).

`sync`, `vendor` and `upstream` remain bash — they are short wrappers around
git commands, which is what shell is good at. `diff` is the exception: deciding
*which* dependencies the divergence rule applies to is the classification rule
again, and a second implementation of it in shell would drift from the first.
So `diff` lives in `suede.py` and the shell script is a wrapper, which also
means CI and the human command cannot disagree about what counts.

---

## The install/git-subrepo contract

suede installs with degit-style extraction and a hand-written `.gitrepo`; `git subrepo` is used only afterwards, for syncing. That handoff is pinned by the integration suite (`.tests/integration/`) and by
the contract test planned in [`PLAN.md`](./PLAN.md) §5.3:

**What works.** A degit-installed folder with a hand-written `.gitrepo` is fully recognised by `git subrepo status`, `pull`, and `push`. No `git subrepo init` or re-clone is needed. Several dependencies installed and committed **together in a single commit** each remain independently pullable — which is why install stages rather than committing per-dependency.

**`parent` must resolve to a real ancestor commit.** Write `parent = $(git rev-parse --verify HEAD)` at install time, i.e. the commit the eventual install commit will descend from. It does **not** need to be the direct parent — unrelated commits landing between install and commit are fine, which is what makes "stage now, commit whenever" safe. A `parent` that isn't in history fails the first `pull` with a message that names the correct recovery SHA.

**The repo must have at least one commit before installing.** On an unborn HEAD, `parent` is written empty and the first `pull` fails with `refusing to merge unrelated histories`. Install itself succeeds and looks healthy, so this breaks silently and surfaces much later. The installer must check for a resolvable HEAD as a precondition.

**Edge symlinks are inert.** A sibling symlink stored at mode `120000` does not disturb `pull` or `push` on the real path, and survives them. But `git subrepo pull <symlink>` **fails** — every subrepo operation must dereference to the real path first, which is what [`sync`](#sync) is for.

**`pull` requires a clean working tree; install does not.** Install works fine on a dirty tree, so `--commit` can be optional. Any install flow that pulls immediately afterwards must account for the difference.

---

## Supporting Scripts

Where each one lives follows from which branch it operates on. A dependency
vendors `.suede/core` from `dependency/main/core` on `main`, and from
`dependency/release/core` on `release` — and the release core is what ships on
to consumers inside an installed dependency.

| Script | Lives in | Because |
| --- | --- | --- |
| [`vendor`](#vendor) | `dependency/main/core` | It rearranges *your* working tree on `main` |
| [`diff`](#diff) | `dependency/main/core` | It audits your release dependencies before you publish |
| `push-release`, `rebuild-pr-branch`, `open-pull-request` | `dependency/main/core` | CI, and all three run against a `main` checkout |
| [`sync`](#sync), `upstream` | `dependency/release/core` | A consumer runs them on a dependency you shipped them |

### `vendor`

Converts a [release dependency](#release-dependency) into a [vendored release dependency](#vendored-release-dependency).

**Accepts** a path to any of: a prefix-named root entry (plain folder **or** symlink), or a backing folder outside `release/` containing a `.gitrepo` that is the target of a prefix-named root symlink. Any form is resolved to the `(backing folder, root entry)` pair and validated before anything moves.

**Does:**

1. `git mv` the backing folder to a destination inside `release/` (default `release/<name>`, where `<name>` is the dependency's own name — the `remote` basename, `.git` stripped — which is also what `install --vendor` calls it; accept a `--dest` override).
2. If the root entry was a symlink, `git rm` it.
3. `grep -r` across `release/` for references to the old entry name and print them as "files to review for refactoring".
4. Read the moved dependency's own manifest and name every sibling it asks for that is not now beside it inside `release/`. Those are what [`check`](#what-the-checks-do-and-dont-enforce) reports as escaping edges, and they have to be vendored too.

### `diff`

Prints a complete diff of the local subrepo against the remote commit named in its `.gitrepo`.

- Excludes the `.gitrepo` file itself (always-divergent local metadata).
- Respects the user's configured `git diff` driver, so a custom difftool is honored.
- Non-empty output ⇒ "this dependency has local modifications," which is the signal [subrepo-push-release](#supporting-actions) uses.

### `sync`

A thin wrapper over `git subrepo pull` that can be run from **any** working directory.

- `cd "$(git rev-parse --show-toplevel)"`, rewrite the target path as repo-root-relative, run the pull, return.
- **If handed a symlink, resolve it to the real folder first.** Confirmed necessary: `git subrepo pull` on a symlink path fails outright.

### `check`

The auditing script. Run post-install and in CI. See [What the checks do and don't enforce](#what-the-checks-do-and-dont-enforce).

### `list`

Prints every dependency, its classification, its resolved target, and its pin. Because classification is implicit in naming, a one-command view of what the tree currently means is the cheapest possible fix for "naming is promotion."

---

## What the checks do and don't enforce

Three different comparisons get confused with each other. They have different verdicts.

| # | Comparison | Verdict | Why |
| --- | --- | --- | --- |
| 1 | A dependency's local files vs **its own recorded commit** | **FAIL** | Your pointer is dishonest — you ship a pointer to code that isn't what you built against. |
| 2 | Your recorded pin vs **what a dependent's manifest asked for** | **INFO** | You took ownership of the resolution. Different commit, different remote, or an entirely hand-written implementation are all legitimate. Surface it in `list`; never fail on it. |
| 3 | A **release** dependency's edge satisfied by a directory that is **not declared as a release dependency of `$repo`** | **FAIL** | This is an implicit dependency — exactly what the flattening rule exists to prevent. |
| 3b | A **vendored** dependency's edge satisfied by a directory **outside `release/`** | **FAIL** | It ships as a link into a directory the consumer never receives. Vendor that one too. |

**Check 3 — the declaration invariant — is the one worth stating precisely:**

> For every entry `N.gitrepo` in every release dependency `D`'s manifest, the sibling `N` must exist, and the directory it resolves to must be the backing folder of some root entry `$repo$SEP X`.

Note what this does **not** compare: not remotes, not commits. It's purely structural — "you didn't resolve anything implicitly." That is what makes check 2 free to be informational. The consumer's declared resolution is authoritative; the check only insists that a resolution _was_ declared.

Note also **whose** manifest it is stated over: a release dependency's. That is the only kind that ships a pointer, so it is the only kind whose resolution a consumer inherits. A development dependency ships nothing and may be satisfied by anything on disk — which is what makes `--dev` installs unprefixed and unrecorded without failing the audit. A vendored dependency ships its own bytes, and check 3b is the same requirement rephrased for it: whatever satisfies its edge has to ship too.

An edge with **no sibling at all** fails whatever the dependent's kind — something imports a path that isn't there.

`check` also warns (not fails) on **dangling entries**: root entries matching `$repo$SEP` that don't resolve or lack a `.gitrepo`. The name signals intent, so silence is the wrong response.

What the scan **doesn't** see: a second checkout of the repository living inside the repository — a `git worktree` parked under `.worktrees/`, a stray clone — is pruned, along with anything under it. Those are the same files seen twice, so walking in would find every install a second time at a path nobody declared, doubling both `list` and every finding. CI clones clean and never sees it; the person running `check` locally does. The marker is a `.git` entry, which a subrepo never has: a dependency carries a `.gitrepo` instead, so none is ever pruned by this.

---

## Migrating from v1

Migration is mostly a **rename**. v1 promoted any root-level `.gitrepo` folder; v2 requires the `$repo$SEP` prefix. A v1 root folder that isn't prefix-named will be reclassified as a **development** dependency under v2 — and silently dropped from `release/.suede/.dependencies/`. To preserve it as a release dependency:

1. `git mv` the folder to its prefixed name: `some-dependency` → `$repo.some-dependency`.
2. Update `release/` imports to the `../$repo$SEP$dependency` form.
3. Run `check` to surface any transitive dependencies that now need declaring at the root — v1 had no flattening rule, so existing trees will have implicit dependencies.

---

## Known Limitations / Gotchas

This approach deliberately does nothing to ensure:

- **Your `release/` code only references configured release dependencies.** If you import something with no backing prefix-named root entry, nothing complains — it just won't be extracted, and downstream consumers silently get a missing sibling. (No static analysis; the system is language-agnostic by design.)
- **Conversely, that dev-only code doesn't reference a release-only path** (or vice versa). Same reason.

Additional sharp edges:

- **`$repo` needs a canonical source.** Classification hinges on knowing the repo's name exactly. Precedence: `--repo-name` flag, `$SUEDE_REPO_NAME`, the `origin` remote's basename, the toplevel working-tree folder name — warning loudly when the last two disagree, since forks and local renames are exactly where this breaks. Repo names may themselves contain dots, which is fine for prefix matching so long as `$repo` is known verbatim, but it makes "guess the prefix by splitting on the first `.`" a non-option.
- **Case-insensitive filesystems.** `app.C` and `app.c` collide on macOS and pass CI on Linux. Prefix comparison should be exact-case, and `check` should warn on case-only collisions.
- **Renaming the repo breaks everything at once.** Every root entry's prefix, every `../$repo$SEP$dep` import (in your code _and_ in every downstream consumer's resolved tree), and every extracted `.gitrepo` filename keys on the repo name. Flattening multiplies the blast radius, since transitive entries carry the prefix too. A repo rename is a coordinated migration, not a cosmetic act.
- **Naming is promotion.** Any `.gitrepo` folder that lands at the root with a matching prefix silently becomes a release dependency. That's far more legible than v1's "any root folder" rule, but the classification is still implicit — [`list`](#list) is the mitigation.
- **"Development" is inferred, never declared.** An install is a development dependency precisely because *nothing* declares it — which makes a typo'd or half-finished release entry indistinguishable from a deliberate `--dev` install. Check 3 exempts both alike, so a dependency that was meant to ship and never got its root entry is exempted for the same reason the dev tooling beside it is. `dangling-entry` catches one shape of the mistake (a correctly-prefixed name with no backing) but not the reverse. Were development declared rather than inferred, check 3 could read as "development dependencies are exempt" instead of "undeclared installs are exempt", and tell the two apart.
- **Two runtime copies under _coexist_.** Where module identity matters — singletons, `instanceof`, class registries, framework context — two copies of the same dependency are two different dependencies. This fails at runtime, not at install, which is what makes it the conflict-resolution failure mode people don't anticipate.
- **Removal leaves orphans.** Remove `B` and `C` remains declared as a release dependency of `app`, possibly with nothing referencing it. A `remove` script should recompute the closure and **report** now-unreferenced entries rather than deleting them — `app` may have started importing `C` directly, and no tool here can see imports.
- **Symlink portability (Windows).** Symlinks are optional upstream (Form A works with zero symlinks) but the **edge entries created downstream are symlinks by default**, so a consumer on native Windows is exposed. Native Windows handles committed symlinks poorly (Developer Mode / admin plus `core.symlinks=true`, and even then a symlink can materialize as a plain text file containing its target path). **The recommendation is to work inside [WSL 2](https://learn.microsoft.com/en-us/windows/wsl/)**, keeping the repo on the Linux filesystem. A devcontainer on Windows already runs on the WSL 2 backend. Where that's impossible, edge entries can be materialized as duplicate folders instead — correct, but N copies of the same commit, N subrepos to pull, and every copy must be checked for divergence.
- **Vendored = nested subrepos.** git-subrepo supports nesting but it's a known rough area.
- **The divergence check is content-only.** It can tell you a release dependency differs from its remote commit, but not _why_ (intentional patch vs. accidental edit) — that judgment stays with the maintainer.

These are accepted tradeoffs to keep the system maximally agnostic: no programming-language support, no config files — just the things every computer ships with already.
