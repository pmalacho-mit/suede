# Migrating `sweater-vest-suede` to suede v2

> Read [the shared notes](./README.md) first for *why* any of this changed.
>
> **Do this last.** It consumes `browser-control-container-suede`, and step 3
> reads that repository's manifest. If it has not been migrated yet, stop and
> migrate it first — the installer will warn you, but the warning is easy to
> read past.

## Where this repository stands today

Verified against `main@79f1f29` and `release@2b5e699`. This is the genuine
two-level case, and it is already laid out the way v2 wants:

```
sweater-vest-suede.browser-control-container-suede  ->  .suede/browser-control-container-suede
sweater-vest-suede.dockview-svelte-suede            ->  .suede/dockview-svelte-suede
sweater-vest-suede.programmatic-docker-suede        ->  .suede/programmatic-docker-suede
sweater-vest-suede.typescript-cli-suede             ->  .suede/typescript-cli-suede

.suede/
  browser-control-container-suede/                      real folder @ 221852c
  browser-control-container-suede.programmatic-docker-suede -> programmatic-docker-suede
  devcontainers-suede/                                  real folder @ 3e8238d
  dockview-svelte-suede/                                real folder @ 54b19e5
  programmatic-docker-suede/                            real folder @ 7959b0e
  typescript-cli-suede/                                 real folder @ 1dd85c3
```

`suede list` today:

| Kind | Entry | Path | Pin |
| --- | --- | --- | --- |
| release | `sweater-vest-suede.browser-control-container-suede` | `.suede/browser-control-container-suede` | `221852c` |
| release | `sweater-vest-suede.dockview-svelte-suede` | `.suede/dockview-svelte-suede` | `54b19e5` |
| release | `sweater-vest-suede.programmatic-docker-suede` | `.suede/programmatic-docker-suede` | `7959b0e` |
| release | `sweater-vest-suede.typescript-cli-suede` | `.suede/typescript-cli-suede` | `1dd85c3` |
| development | — | `.suede/devcontainers-suede` | `3e8238d` |

Three things about this are worth confirming rather than assuming:

**`devcontainers-suede` is a development dependency, and that is correct.** It
has no `$repo.`-prefixed root entry, so the `release` branch knows nothing
about it. If you ever want it shipped, the change is a rename of a root entry,
not a move.

**The nested entry is doing real work.**
`.suede/browser-control-container-suede.programmatic-docker-suede` sits beside
`.suede/browser-control-container-suede/`, which is exactly where that
dependency's edge must be satisfied — a sibling of the dependent. It resolves
to `.suede/programmatic-docker-suede`, which *is* the backing folder of your
root entry `sweater-vest-suede.programmatic-docker-suede`. That satisfies the
declaration invariant, so it passes `check`. Someone set this up correctly and
ahead of time; leave it alone.

**You have already overridden a pin, deliberately or not.** `check` reports:

```
INFO  .suede/programmatic-docker-suede   browser-control-container-suede asks for 1023bf9; you declare 7959b0e
```

This is information, never a failure. `browser-control-container-suede` was
built against `1023bf9`; you resolved its edge to `7959b0e`. The consumer owns
the resolution — that is the whole point. **Decide which you want before
migrating**, because after migration this is what you publish:

- keep `7959b0e` — then `browser-control-container-suede` runs against a commit
  its authors did not test with; or
- move to `1023bf9` — `git -C .suede/programmatic-docker-suede subrepo pull` or
  re-install at that commit, then re-run `check` until only structural findings
  remain.

Neither is wrong. Just do not let it be an accident.

**What is wrong is what you publish.** `release/.dependencies/` contains
**only** `package.json` — not one `.gitrepo` record, despite four release
dependencies. Every consumer of `sweater-vest-suede` today receives a library
whose four dependencies are invisible to them. Step 3 is the fix, and it is the
single highest-value part of this migration.

Your separator is `.` (TypeScript and Svelte — the import specifier is a path
literal).

---

## 1. Rebuild the `release` branch

```bash
git switch release && git pull
git rm -r .github/workflows && git commit -m "suede v2: remove the old workflows"
git subrepo clone https://github.com/pmalacho-mit/suede.git .github/workflows --branch=dependency/release/workflows
git subrepo clone https://github.com/pmalacho-mit/suede.git .suede/core --branch=dependency/release/core
git push origin release
```

> There is a `chore/update-release-*` branch on this repository. Confirm it is
> merged or abandoned before you start; rebuilding `release` underneath an open
> update branch makes the eventual merge much harder to reason about.

## 2. Rebuild `main`

```bash
git switch main
git subrepo pull release
git rm -r .github/workflows && git commit -m "suede v2: remove the old workflows"
git subrepo clone https://github.com/pmalacho-mit/suede.git .github/workflows --branch=dependency/main/workflows
git rm .github/workflows/initialize.yml && git commit -m "suede v2: drop the one-shot initialize workflow"
git subrepo clone https://github.com/pmalacho-mit/suede.git .suede/core --branch=dependency/main/core
```

## 3. Publish the four pointers your consumers cannot currently see

```bash
git rm -r release/.dependencies
bash .suede/core/suede extract
ls release/.suede/.dependencies/
```

Expect exactly five files:

```
package.json
sweater-vest-suede.browser-control-container-suede.gitrepo
sweater-vest-suede.dockview-svelte-suede.gitrepo
sweater-vest-suede.programmatic-docker-suede.gitrepo
sweater-vest-suede.typescript-cli-suede.gitrepo
```

If any of the four is missing, **stop**: its root entry is no longer resolving
to a `.gitrepo` folder outside `release/`, and `suede list` will say which.

Note what these filenames mean for your consumers: each one is a sibling they
must create next to your installed folder, and each matches an import your
`release/` code already makes. `programmatic-docker-suede` appears here even
though your own `release/` code may never import it directly — it is in your
closure because `browser-control-container-suede` needs it, and declaring the
whole closure is what lets a consumer install every pointer once, flat.

## 4. Record the separator

```bash
mkdir -p .suede/.dependencies
printf '.\n' > .suede/.dependencies/separator
```

## 5. Verify, commit, push

```bash
bash .suede/core/suede list     # four release, one development, as above
bash .suede/core/suede check    # exit 0; the INFO line is expected
bash .suede/core/suede diff     # exit 0 — see below

git add -A && git commit -m "suede v2: publish the dependency closure, migrate to the vendored core"
git push origin main
```

---

## The one thing likely to stop you: `diff` across four dependencies

`suede diff` checks each of the four against its pinned commit, and the publish
guard runs the same check. With four dependencies vendored under `.suede/`,
this repository has four chances to have drifted.

For each one it reports, choose deliberately:

| Situation | What to do |
| --- | --- |
| Accidental or obsolete edits | `git checkout -- .suede/<name>/` |
| Edits that belong upstream | `bash .suede/<name>/.suede/upstream`, land the PR, then `git subrepo pull` to re-pin |
| Edits that must ship | `bash .suede/core/vendor.sh .suede/<name>` and fix the imports it prints |

`devcontainers-suede` is **not** checked — it is a development dependency,
ships nothing, and is free to differ. That asymmetry is deliberate: the rule
exists to keep a shipped *pointer* honest, and a development dependency
publishes no pointer.

## Stop and ask if

- `check` reports `undeclared-edge`. One of `dockview-svelte-suede`,
  `typescript-cli-suede` or `programmatic-docker-suede` has gained a dependency
  of its own. It must be declared at your root
  (`bash .suede/core/suede install --repo pmalacho-mit/<name>`) — but
  confirm it is expected first; a new transitive dependency is a real change to
  what you ship.
- The installer warns that a dependency publishes at the pre-2.0 path. That
  dependency has not been migrated. For
  `browser-control-container-suede`, migrate it first. For anything outside
  these three repositories, decide whether to migrate it now or accept a stale
  description of its dependencies.
- The `INFO` pin override disappears or changes. It should say exactly what it
  says today unless you moved `programmatic-docker-suede` on purpose.

## What you are explicitly not doing

- **Not moving anything out of `.suede/`.** Backing folders may live anywhere
  outside `release/`; the prefixed root symlinks are what classify them, and
  they are already correct.
- **Not touching
  `.suede/browser-control-container-suede.programmatic-docker-suede`.** It is
  the edge entry that satisfies your dependency's dependency. Deleting it would
  turn a passing `check` into a `missing-edge` failure.
- **Not renaming `.suede/devcontainers-suede`.** Its lack of a prefix is what
  keeps it out of the `release` branch.
- Not editing `release/.suede/.dependencies/` by hand after step 3.
