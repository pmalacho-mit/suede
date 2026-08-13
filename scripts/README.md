# Scripts

Scripts that share a common prefix are grouped into a folder named after that
prefix, with the prefix stripped from the filename. The hosted URL mirrors the
on-disk path, so `scripts/install/release.sh` is served at both
`https://suede.sh/install/release` and
`https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts/install/release.sh`.

## `suede.py`

The installer. A single dependency-free Python 3.9 file: everything install,
`check`, `list`, `remove` and `extract` do lives here, and every other script
below is either a thin shell around it or a v1 script kept for compatibility.

```bash
python3 suede.py install --repo OWNER/REPO [--dev|--vendor] [--dry-run|--yes|--commit]
python3 suede.py check [--plan-json]
python3 suede.py list  [--json]
python3 suede.py remove <entry>
python3 suede.py extract
```

Consumers normally reach it through the bootstrap rather than downloading it
themselves:

```bash
bash <(curl -fsSL https://suede.sh/install/release) --repo OWNER/REPO
```

It is one readable file on purpose — if you hit a problem on an unusual system,
download it, open it, and patch it. See
[DEPENDENCIES-OF-DEPENDENCIES.md](../DEPENDENCIES-OF-DEPENDENCIES.md) for what a
dependency is and [INSTALL.md](../INSTALL.md) for how one gets installed.

## Removed in v2

These were absorbed into `suede.py`. Their `https://suede.sh/...` URLs now
return a readable 404 rather than a script.

| Removed | What replaced it |
| --- | --- |
| `install/gitrepo.sh` | `suede.py install --gitrepo <path\|->` |
| `utils/degit.sh` | `git clone --depth 1` + a hand-written `.gitrepo`, which the installer does for you |
| `utils/git-raw.sh` | Nothing needs it: all network access goes through `git` |
| `extract/subrepo-config.sh` | `git config -f <file> --get subrepo.<key>` |
| `extract/dependencies.sh` | `suede.py extract` for classification; the install announce block for next steps |
| `populate/dependencies.sh` | `suede.py extract` |
| `actions/push-release.sh` | `dependency/main/core/push-release.sh`, which also runs the publish guard |

`utils/git-raw.sh` and `extract/subrepo-config.sh` were the two places GitHub
was hard-coded. `suede.py` has no such restriction — `git clone` and
`git ls-remote` take a remote verbatim — so GitLab, Codeberg and self-hosted
git work.

## `create/`

### `create/dependency.sh`

Creates a dependency repository from the template, applies the settings the
template README asks for, dispatches the initialization workflow and follows it
to completion — the scripted form of [Creating a
Dependency](../README.md#creating-a-dependency). Needs an authenticated `gh`.

```bash
./scripts/create/dependency.sh <name> [public|private] [--org <org>] [--cleanup]
```

## `install/`

### `install/release.sh`

The bootstrap: finds a Python 3.9+, downloads [`suede.py`](./suede.py), and
hands it the arguments. Every flag belongs to the installer — run
`python3 suede.py install --help` for the full list.

```bash
bash <(curl -fsSL https://suede.sh/install/release) --repo OWNER/REPO [--dev|--vendor]
```

`--dev` installs a development dependency (unprefixed, unrecorded) and
`--vendor` a vendored one (source and all into `release/<name>`). The v1 flags
`--branch` and `--destination` are still accepted and translated: `--branch` is
ignored with a notice, and `--destination` becomes `--name` plus `--target`.

## `populate/`

### `populate/readme-after-init.sh`

Writes installation instructions to README.md by parsing the git remote origin URL.

```bash
./populate/readme-after-init.sh
```

> [!NOTE]  
> Used in [initialize](../templates/dependency/main/.github/workflows/initialize.yml) Github Action

## `upgrade/`

### `upgrade/v1.md`

Step-by-step manual instructions for migrating a repository created with an earlier version of the suede workflow onto the current subrepo layout, where `.suede/core` and `.github/workflows` are vendored from dedicated suede library branches. Rewires both `release` and `main` and drops obsolete generated files (the old per-branch workflow on each side, plus `initialize.yml` on main).

See [upgrade/v1.md](upgrade/v1.md) — and [`migration/`](../migration/) instead if you are also moving to v2, which folds these steps in.

## Subrepo helpers

### `find.sh`

Finds git-subrepo directories (by locating `.gitrepo` files) in the current repository, with optional glob filtering.

```bash
./find.sh [GLOB ...]
```

### `diff.sh`

Shows diffs for the git-subrepo directories discovered via `find.sh`.

```bash
./diff.sh [--force] [TARGET ...]
```

### `pull.sh`

Runs `git subrepo pull` on each discovered subrepo to update it to its latest tracked commit.

```bash
./pull.sh [--dry-run] [TARGET ...]
```

### `push.sh`

Delegates to `pull.sh`, then runs `git subrepo push` on each discovered subrepo.

```bash
./push.sh [--dry-run] [TARGET ...]
```

### `upstream.sh`

Proposes a vendored dependency's local changes upstream as a reviewable PR, without touching the consumed `release` branch.

```bash
bash <(curl https://suede.sh/upstream) <path-to-dependency> [-r|--remote NAME]
```

## `curl` Flags Reference

- `-f` / `--fail` - Fail silently on HTTP errors
- `-s` / `--silent` - Silent mode
- `-S` / `--show-error` - Show errors even in silent mode
- `-L` / `--location` - Follow redirects
