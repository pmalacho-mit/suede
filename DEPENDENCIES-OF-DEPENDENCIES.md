# Dependencies of Dependencies — The 3 Types

This concerns the cases where a [suede](https://github.com/pmalacho-mit/suede) dependency, call it _some-lib_, relies on the source code of one or more other [suede](https://github.com/pmalacho-mit/suede) dependencies — either in _some-lib_'s shipped `release/` code, or only in the development of _some-lib_ on its `main` branch (e.g. for testing, examples, or docs).

The whole idea is that **the kind of a dependency is fully determined by where it lives on `main` and what it is named.** No config file, no manifest, no language-specific tooling. Just folders and names.

Here are the three kinds of dependencies:

- **Release Dependency** — announced by a **root-level entry named `$repo.$dependency` or `$repo__$dependency`**: either a real folder with that name, or a symlink with that name pointing to a folder elsewhere outside `release/`. The backing folder (the entry itself, or the symlink's target) contains a `.gitrepo` file. Your `release/` code references it (via it's full name, e.g. `import {} from "$repo.$dependency"`, `from $repo__$dependency import _`), but you do **not** ship its source; you ship a pointer to its remote commit.
- **Development Dependency** — any suede dependency (a `.gitrepo`-containing folder) outside `release/` that has **no** qualifying prefix-named root entry. The `release` branch knows nothing about it.
- **Vendored Release Dependency** — lives _inside_ `release/`. It ships verbatim with your `release` branch like any other release file.

The goal is the most _boring_ (but still ergonomic) solution. Folders and names — _chef's kiss_.

> `$repo`: the name of the repository, without the `owner/` prefix.

> As a convention, `.` and  `__` are used to separate `$repo` from `$dependency` in **release dependency** paths for typescript and python modules, respectively. This can be freely configured by creating a `config.yml` file inside of the `.suede/` folder on the `main` branch and specify the `release-dependency-separator` property.

## The classification rule

The three types are mutually exclusive and exhaustive. Resolve a dependency by walking this in order:

1. Is the dependency's folder **inside `release/`**? → **Vendored Release Dependency.** (Stop. Names and symlinks are irrelevant here.)
2. Otherwise, is there an entry **at the project root** (same level as `release/`) whose **name begins with `$repo.`**, and whose backing folder — the entry itself if it's a folder, or the symlink's target otherwise — sits **outside `release/`** and contains a `.gitrepo`? → **Release Dependency.**
3. Otherwise → **Development Dependency.**

> [!NOTE]
> [extract/dependencies.sh](https://github.com/pmalacho-mit/suede/blob/main/scripts/extract/dependencies.sh) only ever treats backing folders **outside** `release/` as candidates. So a stray prefix-named symlink pointing _into_ `release/` can never be misread as a release dependency — step 1 already owns everything inside `release/`. This is what keeps the rule robust against leftover links after a [vendor](#vendor).

> [!IMPORTANT]
> **This is a behavior change from v1.** v1 promoted **any** root-level folder containing a `.gitrepo` to a release dependency. v2 promotes only entries carrying the `$repo.` prefix — **the name is the declaration.** A root entry can be a plain folder or a symlink; both qualify identically. This frees the actual subrepo to live **anywhere the author chooses** (when using the symlink form — there is no blessed location) while making the intent legible at a glance: `consumer-lib.some-suede-dependency` reads as "this library is required by _consumer-lib_." It also groups all release dependencies together in a directory listing. See [Migrating from v1](#migrating-from-v1).

## Release Dependency

The most involved case. A release dependency is a suede dependency that your **published** code depends on (code in your `release/` folder references it), but which your dependency will **not** ship directly. Its source appears nowhere on the `release` branch consumed by others — only a `.gitrepo` pointer to it does.

**Why a pointer and not the code?** The `release` branch ships `release/.suede/.dependencies/<entry-name>.gitrepo`, which records the dependency's remote URL and the exact `release`-branch commit you built against. A downstream consumer resolves that pointer themselves (likely in an automated / scripted fashion). This is the feature: the consumer opts in explicitly, can install the exact pinned version, or can substitute their own resolution — all without touching your code.

**The catch that falls out of this:** because you ship a pointer rather than the bytes, the pointer has to be honest. If your local copy of the dependency has been modified beyond the commit named in its `.gitrepo`, then what you built and tested against is **not** what a downstream consumer should resolve. So:

> [!IMPORTANT]
> Release dependencies must **not** contain local modifications relative to their remote commit. This is enforced by the [`diff`](#diff) check, wired into [subrepo-push-release](#supporting-actions): a divergent release dependency fails the push to `release` (the `.gitrepo` file itself is excluded from the comparison, since it's local metadata). If the changes can't be (1) reverted or (2) [upstreamed](#modifying-ie-pushing), convert the dependency to a [Vendored Release Dependency](#vendored-release-dependency) with the [`vendor`](#vendor) script so the code actually ships.

### Layout on `main`

A release dependency can take **either of two equivalent forms** — the classification rule doesn't care which:

**Form A — symlink (indirect).** The real subrepo lives **anywhere the author chooses** — `deps/`, `libs/`, a shared folder, wherever; nothing about the location is special — and a prefix-named root symlink points at it:

```
deps/                              (or any location you like)
  some-suede-dependency/
    .gitrepo
    utility.ts
$repo.some-suede-dependency        →  symlink to deps/some-suede-dependency
release/
  index.ts                         →  imports ../$repo.some-suede-dependency
```

**Form B — plain folder (direct).** The subrepo simply _is_ the prefix-named root folder:

```
$repo.some-suede-dependency/
  .gitrepo
  utility.ts
release/
  index.ts                         →  imports ../$repo.some-suede-dependency
```

Either way, `release/` code imports through the same `../$repo.some-suede-dependency` path — the **name** is what's load-bearing, not the entry's type. This is deliberate: the naming convention enforces exactly how imports of release dependencies must be written from within the code.

The `$repo.` prefix is **required** for classification, but the suffix is free — which is convenient, because it lets one project reference multiple versions of the same suede dependency (each installed separately, each with its own uniquely named entry, e.g. `$repo.some-dep-v1` and `$repo.some-dep-v2`). The prefix also means that, downstream, an installed dependency (likely named the same as its repo) lands in the file tree directly next to the entries that point to _its_ dependencies (see [The invariant](#the-invariant-the-name-is-the-contract)).

### Example

Assume the layout above lives in a repo called _consumer-lib_. Its `release/index.ts` references the dependency through the prefix-named entry:

```ts
// release/index.ts
import { helper } from "../consumer-lib.some-suede-dependency/utility.ts";

helper();
```

The author has declared: "I expect to find _some-suede-dependency_ at `../consumer-lib.some-suede-dependency` — i.e. as a sibling of my folder." [extract/dependencies.sh](https://github.com/pmalacho-mit/suede/blob/main/scripts/extract/dependencies.sh) finds the root entry `consumer-lib.some-suede-dependency`, resolves its backing folder, confirms the folder sits outside `release/` and has a `.gitrepo`, and writes that `.gitrepo` to `release/.suede/.dependencies/consumer-lib.some-suede-dependency.gitrepo`. The dependency's _source_ never enters `release/`.

A downstream repo that installs _consumer-lib_'s `release` branch first receives only the pointer:

```
consumer-lib/                                  (consumer-lib's release/ content, as a subrepo)
  .gitrepo
  .suede/.dependencies/consumer-lib.some-suede-dependency.gitrepo
  index.ts                                     →  imports ../consumer-lib.some-suede-dependency
```

It is then responsible for resolving `consumer-lib.some-suede-dependency`, colocated as a sibling of `consumer-lib/`.

```
consumer-lib/
  .gitrepo
  .suede/.dependencies/consumer-lib.some-suede-dependency.gitrepo
  index.ts
consumer-lib.some-suede-dependency             →  (to be resolved by the consumer)
```

The install script can set up the **exact pinned version** for them, mirroring either upstream form (here, symlink form with a consumer-chosen install location):

```
deps/some-suede-dependency/                    (or wherever the consumer prefers)
  .gitrepo
  utility.ts
consumer-lib/                                  ... same as above ...
consumer-lib.some-suede-dependency             →  symlink to deps/some-suede-dependency
```

> [!NOTE]
> The contract is simply: **a sibling named `$repo.$dependency` exists next to the installed `$repo/` folder and either _is_, or points to, a folder containing the depended-upon code.** Note the pleasing symmetry: this downstream contract is now **exactly the same rule** that classified the dependency upstream. The shape of `main` and the shape of an installed consumer tree are identical — a release dependency looks the same on both sides of the publish boundary. Whether the sibling is a symlink to an install somewhere of the consumer's choosing, a symlink to a shared install, or a plain folder is entirely the consumer's choice — that's the "more control over resolution" benefit (see [Resolving a release dependency](#resolving-a-release-dependency-downstream)).

What's powerful is that the consumer can also resolve the dependency **another way** — their own implementation, a fork, a patched build — with zero change to _consumer-lib_'s code. They simply back the prefix-named sibling with something else. They of course now own the responsibility of making it work...

### Resolving a release dependency (downstream)

The contract is deliberately loose: _something_ named `$repo.$dependency` has to sit next to the installed `$repo/` folder and contain the code. That leaves a genuinely nice fast path.

**Skip the symlink entirely — just install a plain folder.** Because `../$repo.$dependency` resolves the same whether it lands on a symlink or a real directory, a consumer in a hurry can `git subrepo clone` (or otherwise drop) the dependency straight into a folder named **exactly** `$repo.$dependency`, as a sibling of `$repo/` — the install script can (and will) handle the naming. No indirection, no link to create or keep healthy, nothing to mis-target. It just resolves.

```
consumer-lib/
  ...
consumer-lib.some-suede-dependency/            ← a real folder, named exactly like the pointer
  .gitrepo
  utility.ts
```

This is especially good for moving quickly, and it sidesteps the [symlink portability](#known-limitations--gotchas) caveat on platforms where symlinks are awkward. (And since Form B upstream is the same shape, an author on such a platform can avoid symlinks on `main` too.)

**The naming convention quietly protects you here.** Because the sibling is prefixed with the name of the repo that _requires_ it, a resolved folder is scoped to exactly one dependency edge — _consumer-lib_'s need for _some-suede-dependency_. It can never be silently picked up to satisfy a **different** parent's edge to the same underlying dependency: that edge would be looking for its own differently-prefixed sibling (e.g. `other-lib.some-suede-dependency`). Each edge resolves independently; there's no accidental cross-parent sharing. The only cost is possible duplication when several parents pin the same dependency — which is exactly what symlink-mode dedup (below) exists to avoid when you'd rather share one install.

#### Install-script resolution modes

When resolving a `release/.suede/.dependencies/*.gitrepo` pointer, the install script should offer both ends of that tradeoff. Proposed flags (names TBD):

- **`--mode folder` (default):** clone the subrepo directly into the sibling `$repo.$dependency` (the plain-folder fast path above). No symlink to manage, no location to choose — the name _is_ the location.
- **`--mode symlink --target <path>`:** clone the subrepo to the location the user chooses (there is no default location; the whole point is that dependencies live wherever users want) and create the `$repo.$dependency` symlink pointing at it. Useful when the install location should be shared by multiple edges.

On top of the mode, the script should **resolve intelligently** rather than blindly cloning:

- Before installing, check whether the pointer's exact remote + commit is **already present** elsewhere in the repo (resolved by an earlier edge, a shared install the user set up, etc.).
- If so, offer to simply create a `$repo.$dependency` symlink to that existing install instead of re-cloning — dedup by default, with a flag (e.g. `--yes`) to auto-accept for non-interactive / scripted runs.

> [!NOTE]
> **Open:** decide the precedence when both a mode flag and an existing install are in play — e.g. does `--mode folder` suppress the dedup prompt (always independent), or still offer to reuse? A clean default: dedup offers a symlink only in `symlink` mode; `folder` mode is "always independent."

## Development Dependency

Development dependencies are suede dependencies the `release` branch needs to know nothing about: test harnesses, fixtures, example apps, doc generators, benchmarking tools, etc. They live anywhere outside `release/` and are **never** extracted into `release/.suede/.dependencies/`.

The definition is now delightfully simple: **any `.gitrepo`-containing folder that isn't announced by a `$repo.`-prefixed root entry is a development dependency.** There are three natural ways a dependency stays "development":

1. **No root entry at all** — keep it wherever it lives (e.g. `tools/test-helpers/`) and reference it by its real path from your dev/test code. Simplest.
2. **Nested anywhere below the root** — `extract` only scans the project root, so a `.gitrepo` folder (or even a prefix-named entry) tucked under `tests/` is invisible to it.
3. **A root entry with a non-qualifying name** — any name that doesn't begin with `$repo.` is skipped. If you _want_ sibling-style import ergonomics for a dev dependency, pick a different prefix — e.g. a root symlink or folder named `dev.test-helpers`, so dev code can `import ../dev.test-helpers/...` — and it will never be extracted.

> [!NOTE]
> Option 3 is also the escape hatch for "I structured this like a release dependency, but on second thought it's dev-only." Rename the root entry to drop the `$repo.` prefix (e.g. `consumer-lib.test-helpers` → `dev.test-helpers`) and the classification flips — no files moved, though dev-side imports need the matching rename. The reverse promotion is equally a rename.

## Vendored Release Dependency

Vendored release dependencies ship **with** your `release` branch. Because they live _inside_ `release/`, they are just ordinary release content: `subrepo-push-release` copies them to the `release` branch verbatim, source and all.

Use this when a release dependency can't stay pristine — i.e. you've made local modifications you can't revert and can't (or don't want to) upstream — so a `.gitrepo` _pointer_ would no longer describe what the code you ship actually depends on. Vendoring trades the "consumer resolves it themselves" flexibility for "the code is right there, guaranteed correct." Reach for the [`vendor`](#vendor) script to do the move safely.

Things to keep in mind once a dependency is vendored:

- Its `.gitrepo` ships too, so downstream consumers end up with a **nested subrepo** inside their installed `consumer-lib/` subrepo. That's a feature (they can still `git subrepo pull/push` it independently) but also a sharp edge — see [Gotchas](#known-limitations--gotchas).
- Imports change. Code that referenced `../$repo.$dependency` must be repointed at the new in-`release/` location. [`vendor`](#vendor) prints (or at least tries to) the files that need this.
- There's no longer a qualifying root entry, so the classification rule cleanly lands it in step 1. If the release dependency was in symlink form, [`vendor`](#vendor) deletes the link; if it was a plain prefix-named folder, the move into `release/` itself removes it from the root.

## The invariant (the name is the contract)

The single idea holding this together: **the parent-relative path to a release dependency is invariant across the publish boundary.**

On `main`, `release/` and the `$repo.$dep` entries are siblings, and `release/` code references `../$repo.$dep`. Downstream, your `release/` content becomes a folder `$repo/`, and the `$repo.$dep` siblings are recreated next to it — so the very same `../$repo.$dep` resolves identically. Nothing in the shipped code has to change; the consumer only has to reproduce the sibling. And because classification keys on the name rather than on any particular filesystem construct, "reproduce the sibling" means exactly one thing on both sides: _make a correctly named entry exist_.

Symlinks are no longer structurally special — they're an **optional convenience** that buys:

1. **Free physical placement** — the real subrepo can live anywhere the author likes while the named marker sits at the root.
2. **Shared installs** — several edges (or several repos) can point at one physical copy.
3. **Resolution control** — a consumer can repoint an entry at a fork, a shared install, or their own implementation without renaming anything.

When none of those matter, a plain prefix-named folder does the job with zero moving parts — upstream and downstream alike.

## Supporting Scripts

These belong in [dependency/release/core](https://github.com/pmalacho-mit/suede/tree/main/dependency/release/core) (the collection of scripts a user runs to perform suede-specific tasks).

### `vendor`

Converts a [release dependency](#release-dependency) into a [vendored release dependency](#vendored-release-dependency).

**Accepts** a path to any of:
1. a `$repo.`-prefixed root entry (plain folder **or** symlink), or
2. a backing folder outside `release/` containing a `.gitrepo` that is the target of a `$repo.`-prefixed root symlink.

Any form is resolved to the `(backing folder, root entry)` pair and validated as a genuine release dependency before anything moves.

**Does:**
1. `git mv` the backing folder to a destination inside `release/` (default e.g. `release/.suede/vendor/<name>`; accept a `--dest` override).
2. If the root entry was a symlink, `git rm` it. (If the root entry _was_ the folder, step 1 already removed it from the root.)
3. `grep -r` across `release/` for references to the old entry name and print them as "files to review for refactoring" — these imports now have to point at the new in-`release/` location.

> [!NOTE]
> **Verify:** confirm `git mv` of a subrepo plays nicely with `git subrepo`. The `.gitrepo` file does not record its own path (only remote/branch/commit/parent), so a move _should_ leave future `git subrepo pull/push` working as long as they're invoked against the new path — but this needs a real test, including a subsequent `pull` round-trip.

### `diff`

Prints a complete diff of the local subrepo against the remote commit named in its `.gitrepo`.

- Excludes the `.gitrepo` file itself from the comparison (always-divergent local metadata).
- Respects the user's configured `git diff` driver where possible, so a custom difftool is honored.
- Exit non-zero / non-empty output ⇒ "this dependency has local modifications," which is exactly the signal [subrepo-push-release](#supporting-actions) uses.

> [!NOTE]
> **Open:** decide whether `diff` fetches the remote commit on demand (robust, needs network) or assumes it's already fetched (fast, can be stale). The action and the local-dev use case may want different defaults.

### `sync`

A thin wrapper over `git subrepo pull` that can be run from **any** working directory (plain `git subrepo pull` must run from the repo root).

- `cd "$(git rev-parse --show-toplevel)"`, rewrite the target path as repo-root-relative, run the pull, return.
- If handed a symlink, resolve it to the real folder first (git-subrepo operates on the real path).

> [!NOTE]
> **Open:** symmetric `push` convenience too, or keep `sync` pull-only to avoid encouraging accidental pushes?

## Supporting Actions

[subrepo-push-release](https://github.com/pmalacho-mit/suede/blob/main/dependency/main/workflows/subrepo-push-release.yml) must gain a guard, downstream of `extract/dependencies.sh` and **before** it pushes `release/` to the `release` branch:

1. For each [release dependency](#release-dependency) (prefix-named root entry → backing folder), run [`diff`](#diff).
2. If **any** dependency diverges from its remote commit, the action must:
   - **Return early without touching the `release` branch** (the push simply doesn't happen).
   - **Update `README.md`** via a managed status block (same pattern as the existing `<!-- TOKEN-STATUS -->` block), naming which release dependencies diverged.
   - **Print guidance** on the two ways out: [`vendor`](#vendor) the dependency, or [upstream](#modifying-ie-pushing) its changes with `git subrepo push`.

> [!NOTE]
> **Optional hook:** if a script named `fail-on-divergent-release-dependency.sh` exists in the repo's `.suede/` folder, invoke it on failure so users can customize behavior (open an issue, post to Slack, tailor the message, etc.). Worth deciding the exact filename/contract before relying on it.

## Migrating from v1

Migration is now mostly a **rename**. v1 promoted any root-level `.gitrepo` folder; v2 requires the `$repo.` prefix. So a v1 root folder that isn't prefix-named will be reclassified as a **development** dependency under v2 — and silently dropped from `release/.suede/.dependencies/`. To preserve it as a release dependency:

1. `git mv` the folder to its prefixed name: `some-dependency` → `$repo.some-dependency`. (That's it for classification — Form B. Optionally, move the real folder anywhere you like and leave a prefix-named symlink at the root — Form A.)
2. Update `release/` imports to the `../$repo.$dependency` form.

> [!NOTE]
> **Open:** alternatively, `extract` could accept _both_ bare v1 root folders and v2 prefix-named entries for a transition period. But since the v2 migration is a single `git mv` plus an import find-and-replace, a grace window may not be worth the ambiguity it introduces.

## Known Limitations / Gotchas

This approach deliberately does nothing to ensure:

- **Your `release/` code only references configured release dependencies.** If you import something that has no backing prefix-named root entry, nothing complains — it just won't be extracted, and downstream consumers silently get a missing sibling. (No static analysis; the system is language-agnostic by design.)
- **Conversely, that dev-only code doesn't reference a release-only path** (or vice versa). Same reason.

Additional sharp edges worth documenting:

- **`$repo` needs a canonical source.** Classification hinges on knowing the repo's name exactly. Decide (and document) where `extract` reads it from — the toplevel working-tree folder name? the `origin` remote's basename? an explicit override (env var / flag) for when they disagree (forks, local renames)? Repo names may themselves contain dots (legal on GitHub), which is fine for prefix matching so long as `$repo` is known verbatim — but it makes "guess the prefix by splitting on the first `.`" a non-option. Also mind case: prefix comparison should probably be exact-case, and case-insensitive filesystems can mask a casing mismatch that then breaks on Linux CI.
- **Renaming the repo breaks everything at once.** Every root entry's prefix, every `../$repo.$dep` import (in your code _and_ in every downstream consumer's resolved tree), and every extracted `.gitrepo` filename keys on the repo name. A repo rename is now a coordinated migration, not a cosmetic act. Worth a loud note — and perhaps a `rename` helper script someday.
- **Naming is promotion.** Any `.gitrepo` folder that lands at the root with a matching prefix silently becomes a release dependency — there's no separate "declare" step beyond the name itself. That's far more legible than v1's "any root folder" rule (the name at least announces intent), but the classification is still implicit; a `list-dependencies` script that prints each dependency and its classification would make the current state auditable at a glance.
- **Symlink portability (Windows).** Symlinks are now fully optional — Form B (plain prefix-named folders) works upstream and downstream with zero symlinks, which defuses most of the historical Windows risk. For those who _do_ want the symlink indirection (Form A), the standing advice applies: native Windows handles committed symlinks poorly (Developer Mode / admin plus `core.symlinks=true`, and even then a symlink can materialize as a plain text file containing its target path). **The recommendation is to work inside [WSL 2](https://learn.microsoft.com/en-us/windows/wsl/)**, keeping the repo on the Linux filesystem (e.g. `~/projects/...`, not `/mnt/c/...`) and, if using VS Code, pairing it with the Remote-WSL extension. A devcontainer on Windows already runs on the WSL 2 backend, so anyone following the recommended [devcontainer](https://containers.dev/) flow is covered.
- **Dangling entries aren't validated.** A prefix-named symlink whose target was moved/deleted — or a prefix-named folder that lost its `.gitrepo` — will simply stop classifying as a release dependency (or resolve to nothing) with no warning. `extract` could at least warn on prefix-named entries it finds but rejects, since the name signals intent.
- **Vendored = nested subrepos.** A vendored release dependency ships its `.gitrepo`, so consumers get a subrepo inside a subrepo. git-subrepo supports nesting but it's a known rough area; document it where you describe vendoring.
- **The divergence check is content-only.** It can tell you a release dependency differs from its remote commit, but not _why_ (intentional patch vs. accidental edit) — that judgment stays with the maintainer.

These are not by design in any deep sense, but they're accepted tradeoffs to keep the system maximally agnostic: no programming-language support, no config files — just the things every computer ships with already.
