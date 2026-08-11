# [Suede](https://github.com/pmalacho-mit/suede) Core (`main`)

Vendored at `.suede/core` on your dependency's **`main`** branch. These are the
maintainer's tools and the scripts CI runs — none of them ship to consumers.
(The consumer-facing half is vendored from `dependency/release/core` onto the
`release` branch, at the same path.)

This folder is a [git-subrepo](https://github.com/ingydotnet/git-subrepo) of the
suede library, so you get fixes by pulling rather than by editing:

```bash
git subrepo pull .suede/core
```

## What CI runs

You do not invoke these by hand; the workflows in `.github/workflows` call them,
and they live here rather than in YAML so they can be tested without a runner.

### [push-release.sh](./push-release.sh)

The whole publish flow, run by `subrepo-push-release` when a change under
`release/` lands on `main`: regenerate the dependency manifest, **guard**, then
sync `release/` out to the `release` branch.

The guard is the part worth knowing about. A release dependency ships as a
*pointer*, so before that pointer goes out it checks the pointer is honest
(`suede diff` — nothing has drifted from its pinned commit) and that nothing is
resolved implicitly (`suede check`). If either fires, the reason goes into the
job summary and **the `release` branch is not touched**, so consumers stay on
the last honest version.

```bash
DRY_RUN=1 bash .suede/core/push-release.sh   # stop after the guard
```

`RELEASE_DIR` (default `release`) overrides which folder is published, and
`SUEDE_PY` overrides where [`suede`](./suede) fetches the installer from.

### [rebuild-pr-branch.sh](./rebuild-pr-branch.sh)

Turns a consumer's `git subrepo push` into something you can review. Given the
`downstream/**` branch their push created, it recovers the release commit they
branched from, replays their change onto the current release (conflicts become
markers), and transplants the result under `release/` on top of `main`.

Run by `suede-downstream-to-main`, which lives on the `release` branch but
checks out `main` — which is why this script is here and not in `release/core`.

### [open-pull-request.sh](./open-pull-request.sh)

Composes the PR description for that rebuilt branch and opens it. "Open a PR" is
the one step that differs between forges, so it sits behind a backend switch:
`gh` on GitHub, the Gitea API in the offline test harness, and `print` to see
the description without opening anything.

```bash
SUEDE_PR_BACKEND=print bash .suede/core/open-pull-request.sh   # dry run
```

## What you run

### [diff.sh](./diff.sh)

Every release dependency that no longer matches the commit its `.gitrepo` names.
Non-empty output means your pointer is dishonest — you would ship a pointer to
code that is not what you built against. The publish guard runs the same check,
so a clean `diff` here means a publish that will not be refused for that reason.

```bash
bash .suede/core/diff.sh
```

Vendored dependencies are exempt: one exists precisely *because* it diverges,
and it ships as source rather than as a pointer. Development dependencies ship
nothing at all, so they are exempt too.

If it reports divergence you have three honest options — revert the changes,
[upstream](../../release/core/README.md) them, or vendor the dependency.

### [vendor.sh](./vendor.sh)

Converts a release dependency into a **vendored** one: moves it inside
`release/` so its source ships with your `release` branch instead of a pointer.

Reach for it when a dependency cannot stay pristine — you have local
modifications you can neither revert nor upstream — because at that point a
pointer no longer describes what your code actually depends on.

```bash
bash .suede/core/vendor.sh <entry-or-folder> [--dest release/.suede/vendor/<name>]
```

It prints the files referencing the old entry name; their imports need
repointing. Afterwards its `.gitrepo` ships too, so consumers get a nested
subrepo — a feature (they can still pull and push it independently) and a sharp
edge.

### [suede](./suede)

Runs the installer. Everything `check`, `list`, `diff`, `extract`, `install` and
`remove` do lives in one dependency-free Python 3.9 file.

```bash
bash .suede/core/suede list     # every dependency, its kind and pin
bash .suede/core/suede check    # audit the tree
bash .suede/core/suede extract  # regenerate release/.suede/.dependencies/
```

It is a thin bootstrapper, the same shape as `upstream` on the release side:
the installer is **hosted, not vendored**, so a fix reaches every repository as
soon as it is pushed to the library rather than waiting on a `git subrepo pull`
in each one. `SUEDE_PY` points it somewhere else — a local path for tests, or a
pinned URL (`https://suede.sh/suede?ref=v2.0.0`) if you would rather a
publish never change underneath you.

It needs `python3` on PATH; the installer checks its own version and explains
itself if it is older than 3.9.
