# Migrating `typescript-cli-suede` to suede v2

> The mechanics are in [any-suede-dependency.md](./any-suede-dependency.md);
> this records what *this* repository looks like and what is specific to it.
>
> Migrate before `sweater-vest-suede`, which depends on it. First wave.

## Where this repository stands today

**This is the only one of the six already on the upgraded subrepo layout** —
someone has run [`scripts/upgrade/v1.md`](../scripts/upgrade/v1.md) here. That
makes it **shape 2**, and its migration is much shorter: no branch rebuilds, no
`subrepo clone`, just pulls.

Verified against `main`:

| | |
| --- | --- |
| Shape | **2 — upgraded** |
| `.suede/core` | present, subrepo of `dependency/main/core` (currently only a README — the scripts are new) |
| `.github/workflows` | present, subrepo of `dependency/main/workflows` |
| `release/.suede/core` | present, with `upstream` |
| `release/.github/workflows` | present |
| Suede dependencies | `.suede/devcontainers-suede` — **development**, correctly |
| Manifest | **both** `release/.dependencies/package.json` **and** `release/.suede/.dependencies/package.json` |
| Separator | `.` — TypeScript (`index.ts`, `flag.ts`) |

`suede list` shows one row — `.suede/devcontainers-suede`, development — and
`check` passes. The `.suede/core` and `.github/workflows` subrepos are
deliberately not listed: they are suede's plumbing, not dependencies.

## The two things specific to this repository

**1. You have two manifests, and suede reads the newer one.** Both
`release/.dependencies/` and `release/.suede/.dependencies/` exist, each with a
`package.json`. suede prefers the current path, so nothing is misbehaving today
— but the legacy copy is stale the moment anything changes, and whoever finds
it next has no way to know which is live. Delete it in step 4.

**2. `.suede/core` is a subrepo, so you get the new scripts by pulling.** Every
other repository in this estate has to `subrepo clone` the core in; here it is
already wired up and one `git subrepo pull` brings in `push-release.sh`,
`suede.py`, `diff.sh` and the rest. That is the whole point of the layout: this
repository will get every future fix the same way.

## What to do

Follow [the general guide](./any-suede-dependency.md) as **shape 2**:

```bash
git switch main && git pull
git subrepo pull .suede/core
git subrepo pull .github/workflows
git rm .github/workflows/initialize.yml 2>/dev/null && git commit -m "suede v2: drop the one-shot initialize workflow" || true

git switch release && git pull
git subrepo pull .suede/core
git subrepo pull .github/workflows
git push origin release
git switch main && git subrepo pull release
```

Then steps 4–6, with:

- **Step 4** — remove only the legacy directory; the current one is regenerated:
  ```bash
  git rm -r release/.dependencies
  python3 .suede/core/suede.py extract
  ```
  Expect `release/.suede/.dependencies/package.json` and no `.gitrepo` records:
  `devcontainers-suede` is a development dependency and is deliberately never
  published.
- **Step 5** — the separator is `.`. Note `.suede/.dependencies/` already exists
  here and is empty; the separator file is what goes in it.

## Stop and ask if

- `git subrepo pull .suede/core` conflicts. It would mean someone edited the
  vendored core in place. Those edits belong upstream in this library, not here
  — resolve in favour of the pull and re-apply them there.
- `.suede/devcontainers-suede` starts showing as `release` rather than
  `development`. That means a `typescript-cli-suede.`-prefixed root entry
  appeared pointing at it, which would start publishing your devcontainer
  config as a dependency.
