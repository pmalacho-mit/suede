# Migrating `programmatic-docker-suede` to suede v2

> The mechanics are in [any-suede-dependency.md](./any-suede-dependency.md);
> this records what *this* repository looks like and what is specific to it.
>
> **Migrate this one first.** `browser-control-container-suede` depends on it,
> and `sweater-vest-suede` depends on that. It is the root of the chain.

## Where this repository stands today

Verified against `main`:

| | |
| --- | --- |
| Shape | **1 — pre-upgrade** (`.suede/core` absent, `.github/workflows` holds only `subrepo-push-release.yml`) |
| Suede dependencies | **none** — `release/.gitrepo` is the only `.gitrepo` in the tree |
| Manifest | `release/.dependencies/package.json` — legacy path, no `.gitrepo` records (there are none to have) |
| Separator | `.` — TypeScript (`index.ts`, `exec.ts`, `CommandStream.ts`, `devcontainer.ts`) |

`suede list` reports nothing and `suede check` passes, and both will still be
true when you are done. This is a workflow and manifest-layout migration only —
no dependency graph to reason about.

## What to do

Follow [the general guide](./any-suede-dependency.md) as **shape 1**, all six
steps, with these specifics:

- **Step 4** — there are no `.gitrepo` records to produce. Expect
  `release/.suede/.dependencies/package.json` and nothing else. Remove the
  legacy directory in the same commit:
  ```bash
  git rm -r release/.dependencies
  bash .suede/core/suede extract
  ```
- **Step 5** — the separator is `.`:
  ```bash
  mkdir -p .suede/.dependencies && printf '.\n' > .suede/.dependencies/separator
  ```
- **Step 6** — `suede diff` has nothing to compare, so it exits 0 trivially.
  Do not read that as "the guard works"; it will start doing real work the
  first time this repository takes a release dependency of its own.

## Why this one matters more than its size suggests

Two consumers resolve pointers *to* this repository, and one of them
(`browser-control-container-suede`) currently publishes a record naming it. The
day `browser-control-container-suede` migrates, its manifest will ask consumers
for a sibling named `browser-control-container-suede.programmatic-docker-suede`
— so what you publish here has to be resolvable and honest before that lands.

Nothing in this repository needs to change to make that work. It just needs to
be on the current layout first.

## Stop and ask if

- `suede list` reports anything. It should report nothing; if a `.gitrepo`
  folder has appeared, use
  [browser-control-container-suede.md](./browser-control-container-suede.md) as
  the model rather than improvising.
- The `release` branch has commits you do not recognise — it is generated from
  `main`.
