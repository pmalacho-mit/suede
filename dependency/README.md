# Dependency

This folder gathers, in one place, all the moving parts that make up a [suede dependency](https://github.com/pmalacho-mit/suede) — so they can be viewed, edited, and synced from this single repo.

Every part is brought in as a [git-subrepo](https://github.com/ingydotnet/git-subrepo) (hence the `.gitrepo` files), and each tracks a branch of either this repo or the external template repo. See [Editing & syncing](#editing--syncing) below before changing anything.

## Layout

There is a top-level folder for each branch of a suede dependency — [`main`](./main/) (development) and [`release`](./release/) (distribution). Each branch-specific folder contains the same three subfolders:

- **`core/`** — suede-specific helper files that get vendored into the dependency.
  - On `release`, these ship to **consumers** (e.g. the [`upstream`](./release/core/upstream) script, which proposes a consumer's local changes back to the library as a PR).
  - On `main`, these assist the **maintainer** (currently none).
  - Each folder is a [subrepo](https://github.com/ingydotnet/git-subrepo) clone of this repository pointed at a branch matching it's path
- **`workflows/`** — the [GitHub Actions](https://github.com/features/actions) files that drive a suede dependency's automated branch coordination (e.g. `initialize.yml` and `subrepo-push-release.yml` on `main`; `suede-downstream-to-main.yml` on `release`).
  - This is the **canonical place to author workflow files** — not [`template/.github/workflows/`](#editing--syncing).
  - Each folder is a [subrepo](https://github.com/ingydotnet/git-subrepo) clone of this repository pointed at a branch matching it's path
- **`template/`** — a [subrepo](https://github.com/ingydotnet/git-subrepo) clone of the external [`suede-dependency-template`](https://github.com/pmalacho-mit/suede-dependency-template) repo (either it's `main` or `release` branch), which is what new dependency repos are created from.
  - Contains a **nested** subrepo at `template/.github/workflows/`, which points to the corresponding `dependency/<branch>/workflows` branch of this repository. 
    - **_NOTE:_** For simplicity, **DO NOT EDIT** these files and prefer instead to update the corresponding `dependency/<branch>/workflows` location (which can then be `git subrepo push`ed, and then `git subrepo pull` can be invoked within the [`suede-dependency-template`](https://github.com/pmalacho-mit/suede-dependency-template) repo)

## Editing & syncing

- **`core/` and `workflows/`** are fully editable here and support bidirectional syncing — edit the files in place, then `git subrepo push` to send the changes back to their branch (and `git subrepo pull` to update).

- (As a convention) **`template/`** is editable **only** for files that do **not** live inside a nested subfolder that has its own `.gitrepo`. For example, [`template/README.md`](./main/template/README.md) is editable and syncs back to its remote, but **`template/.github/workflows/` should not be edited here** (since it is a subrepo within a subrepo, syncing changes is less straight forward).
  - Instead, edit the source branch named in that folder's `.gitrepo`. In practice, the edit target for `dependency/<branch>/template/.github/workflows` is simply [`dependency/<branch>/workflows`](#layout) (e.g. to change a `main` workflow, edit `dependency/main/workflows`, not `dependency/main/template/.github/workflows`).

## In practice

In a fully initialized dependency repo, you'd have the following branch & folder structure

- `main` (branch)
  - .devcontainer
    - devcontainer.json (symlink to /.suede/devcontainers-suede/common.json)
  - .github/workflows/
    - .gitrepo (points to [dependency/main/workflows](https://github.com/pmalacho-mit/suede/tree/dependency/main/workflows))
    - ... files ...
  - .suede/
    - core/
      - .gitrepo (points to [dependency/main/core](https://github.com/pmalacho-mit/suede/tree/dependency/main/core))
      - ... files ...
    - devcontainers-suede/
      - .gitrepo (points to `release` branch of [pmalacho-mit/devcontainers-suede](https://github.com/pmalacho-mit/devcontainers-suede))
      - ... files ...
  - release/
    - .gitrepo (points to `release` branch of dependency repo)
    - ... files (see below) ...
- `release` (branch)
  - .github/workflows
    - .gitrepo (points to [dependency/release/workflows](https://github.com/pmalacho-mit/suede/tree/dependency/release/workflows))
    - ... files ...
  - .suede/core
    - .gitrepo (points to [dependency/release/core](https://github.com/pmalacho-mit/suede/tree/dependency/release/core))
    - ... files ...
