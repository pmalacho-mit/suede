# Installing — what the installer does, and what it leaves to you

The installer is one bash script,
[`scripts/install/release.sh`](./scripts/install/release.sh). It does five
things and then stops. Everything after that — resolving the dependency's own
dependencies, third-party packages, committing — is yours, and the tools
describe it rather than doing it. That is deliberate: the previous installer
resolved whole dependency graphs for you, and when it guessed wrong there was
nothing to do but take it apart by hand.

```bash
bash <(curl -fsSL https://suede.sh/install/release) --repo OWNER/REPO
```

## 1. What it does

Run it **in the directory where you want the dependency**.

1. **Resolve.** `OWNER/REPO` means `github.com`; any git URL or local path is
   taken as given. The `release` branch's tip is looked up (`--branch` and
   `--at <commit>` override), trying the SSH spelling first and HTTPS second —
   see [Remotes](#4-remotes).
2. **Fetch.** The commit's tree — no history — lands in `./<name>`, where
   `<name>` is the repository's name. `--name`, `--prefix` and `--suffix`
   change it. If `./<name>` already exists the installer refuses and names those
   three flags; it never merges into or replaces a folder.
3. **Record.** A `.gitrepo` is written in the folder with the remote, branch,
   commit and this repository's `HEAD` as `parent`, exactly as `git subrepo
   clone` would have, so `sync` and `upstream` work later.
4. **Declare** — or not. See [the three places](#2-where-you-run-it-decides-what-it-means).
5. **Stage.** Everything is `git add`ed, nothing is committed. Then the
   dependency's own [`deps.sh`](./dependency/release/core/README.md#depssh)
   runs, so you see what it needs beside it before you commit.

## 2. Where you run it decides what it means

| You run it… | What happens | The dependency is |
| --- | --- | --- |
| at the root of a repository that has `release/.gitrepo` (a suede dependency) | the folder, plus a symlink `<repo><sep><name> -> <name>` beside it | a **release dependency**: `extract` publishes it, consumers get it |
| the same, with `--dev` | the folder only | a **development dependency**: nothing is published |
| inside that repository's `release/` | the folder only | a **vendored release dependency**: its source ships |
| anywhere in a repository with no `release/.gitrepo` | the folder only | a dependency of an application; there is nothing to publish |

`<repo>` is your repository's name (what `origin` calls it, else the folder)
and `<sep>` is `.` unless you pass `--sep` — use `__` where a path segment has
to be a legal identifier, as in Python or Rust. Forgot it? Rename the symlink.
Changed your mind about declaring? Delete the symlink. **The symlink is the
whole declaration**, so both are ordinary `git mv` and `git rm`.

A release install anywhere other than the repository root is refused: code in
`release/` reaches a release dependency as `../<repo><sep><name>/...`, and that
path only holds when the symlink sits beside `release/`. The installed folder
and its symlink always share a parent — the symlink is never placed somewhere
else for you, because symlinks followed across directories behave differently
in different languages' module resolution.

## 3. What it leaves to you, and how it tells you

A dependency publishes its own dependencies as records in
`.suede/.dependencies/`, one `<sibling>.gitrepo` each, and expects to find
`<sibling>` **next to itself**. `deps.sh` reads those and prints a recipe:

```
deps: sweater needs 2 sibling(s) at the repository root

[1] sweater.dockview
    https://github.com/pmalacho-mit/dockview-svelte-suede @ 4f10c2a
    not installed anywhere in this repository
    bash <(curl -fsSL https://suede.sh/install/release) --repo https://github.com/pmalacho-mit/dockview-svelte-suede --at 4f10c2a...
    ln -s dockview-svelte-suede sweater.dockview

    [1.1] dockview.mixin
        https://github.com/pmalacho-mit/mixin-suede @ 9bb0e41
        not installed anywhere in this repository
        bash <(curl -fsSL https://suede.sh/install/release) --repo https://github.com/pmalacho-mit/mixin-suede --at 9bb0e41...
        ln -s mixin-suede dockview.mixin

[2] sweater.mixin
    https://github.com/pmalacho-mit/mixin-suede @ 9bb0e41
    same install as [1.1]
    ln -s mixin-suede sweater.mixin

deps: 0 satisfied, 3 to resolve.
```

Paste the commands, run from the root, re-run `deps.sh` to confirm. Each
install in the recipe is itself declared (the `<repo><sep><name>` symlink) when
you are in a dependency repository, so the transitive closure ends up declared
at your root without a rule saying it must.

When something is **already on disk** the recipe changes shape. Same repository,
same commit, no local changes: one `ln -s`. Anything else — a different commit,
or local edits — and `deps.sh` shows you the `diff --at <commit>` that exposes
the difference and offers both ways out: link the edge to what you have and own
the difference, or install exactly what was asked for under another name
(`--name mixin-suede-9bb0e41`) and link to that. It does not choose.

## 4. Remotes

The installer's own git calls try the **SSH** spelling first, so a key in your
environment is enough for a private repository, and **HTTPS** second, so a
machine with no key still installs anything public. Both fail fast
(`BatchMode=yes`, five-second connect timeout) and never prompt.

The live `.gitrepo` records the SSH spelling whichever one answered, because
that is the one `upstream` can push through; HTTPS no longer offers an
authenticated write. What you *publish* (`extract`) records the HTTPS spelling,
because a consumer or a CI runner resolving your records holds no key of yours.
A local path or a non-hosted URL has one spelling and is recorded as given.

The scripts that ship inside every dependency follow the same rule, the other
way round: `diff`, `deps.sh` and `sync` try the **recorded** remote first and
its other spelling second. That is what lets the publish guard compare an
SSH-recorded dependency on a CI runner, which has no key. `upstream` is the
exception, because pushing needs the SSH spelling and an HTTPS fallback could
not authenticate anyway.

## 5. Third-party packages

Not the installer's business. A dependency's `release/` folder is a package in
its own right — give it a `package.json` (or `pyproject.toml`) naming what its
code imports, and treat it as a **workspace** on both sides:

```jsonc
// the dependency's own root package.json, on main
{ "workspaces": ["release"] }

// a consumer's root package.json
{ "workspaces": ["sweater-vest-suede", "dockview-svelte-suede", "mixin-suede"] }
```

One `npm install` at the root then resolves every dependency's packages. The
installer never edits `package.json`, `requirements.txt` or a lockfile.

## 6. Flags

```
--repo <OWNER/REPO | url>   required
--at <commit>               install this commit instead of the branch tip
--branch <name>             install from this branch (default: release)
--sep <text>                separator for the declaring symlink (default: .)
--name <folder>             install under this name instead of the repo's
--prefix <text>             prepend to the folder name
--suffix <text>             append to the folder name
--dev                       never create the declaring symlink
```

Exit `0` on success, `1` on any failure. Nothing is written before the fetch
succeeds, and a failure after it leaves at most the new folder, which `git
status` shows.

## 7. Removing a dependency

`git rm -r <name>` and `git rm <repo><sep><name>`, then `deps.sh` on anything
that pointed at it will tell you which edge symlinks now dangle. There is no
command for this because there is nothing for a command to know that `git
status` does not.
