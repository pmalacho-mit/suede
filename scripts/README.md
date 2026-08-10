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
python3 suede.py install --repo OWNER/REPO [--dry-run|--yes|--commit]
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

## Deprecated

These are v1 endpoints. They still work — the URLs are copied into READMEs and
shell histories — but they forward to `suede.py` or are superseded by it, and
they will be removed after one release.

| Endpoint | Use instead |
| --- | --- |
| `install/gitrepo.sh` | `suede.py install --gitrepo <path\|->` (the shim forwards to it) |
| `utils/degit.sh` | `git clone --depth 1 --branch release`, which `suede.py` does for you |
| `utils/git-raw.sh` | Nothing needs it: all network access now goes through `git` |
| `extract/subrepo-config.sh` | `git config -f <file> --get subrepo.<key>` |
| `extract/dependencies.sh` | `suede.py extract` for classification; the install announce block for next steps |

`utils/git-raw.sh` and `extract/subrepo-config.sh` are also the two places
GitHub was hard-coded. `suede.py` has no such restriction — `git clone` and
`git ls-remote` take a remote verbatim — so GitLab, Codeberg and self-hosted
git work.

## `extract/`

### `extract/subrepo-config.sh`

Parses a git-subrepo `.gitrepo` file from stdin and outputs `OWNER`, `REPO`, and `COMMIT` as `KEY=VALUE` pairs.

```bash
cat .gitrepo | bash <(curl https://suede.sh/extract/subrepo-config)
```

### `extract/dependencies.sh`

Summarizes the `.suede/.dependencies` of an installed gitrepo and prints NEXT STEPS (npm install line + nested suede dependencies to install).

```bash
bash <(curl https://suede.sh/extract/dependencies) <dest> [--message TEXT] [--emit-add-targets]
```

## `install/`

### `install/release.sh`

Fetches a `release/.gitrepo` file from a remote repository and downloads the referenced release archive.

```bash
bash <(curl https://suede.sh/install/release) --repo OWNER/REPO [--branch BRANCH] [--destination DIR]
# Defaults: --branch=main, --destination=./<repo-name>
```

### `install/gitrepo.sh`

**Deprecated.** Translates the v1 arguments and hands over to the bootstrap, so
a copied URL keeps working for one release.

```bash
bash <(curl -fsSL https://suede.sh/install/gitrepo) -d <destination> [<file.gitrepo>|-]
```

## `populate/`

### `populate/dependencies.sh`

Collects dependency metadata into `release/.suede/.dependencies/`: copies `.gitrepo` files from child folders, extracts package.json dependencies, and copies requirements.txt.

```bash
./populate/dependencies.sh
```

> [!NOTE]  
> Used in [subrepo-push-release](../templates/dependency/main/.github/workflows/subrepo-push-release.yml) Github Action

### `populate/readme-after-init.sh`

Writes installation instructions to README.md by parsing the git remote origin URL.

```bash
./populate/readme-after-init.sh
```

> [!NOTE]  
> Used in [initialize](../templates/dependency/main/.github/workflows/initialize.yml) Github Action

## `upgrade/`

### `upgrade/README.md`

Step-by-step manual instructions for migrating a repository created with an earlier version of the suede workflow onto the current subrepo layout, where `.suede/core` and `.github/workflows` are vendored from dedicated suede library branches. Rewires both `release` and `main` and drops obsolete generated files (the old per-branch workflow on each side, plus `initialize.yml` on main).

See [upgrade/README.md](upgrade/README.md).

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

## `utils/`

### `utils/degit.sh`

Downloads a GitHub repository archive at a specific commit/branch without cloning.

```bash
bash <(curl https://suede.sh/utils/degit) --repo OWNER/REPO [--commit SHA] [--branch BRANCH] [--destination DIR] [--include PATH...]
# Defaults: --branch=<default-branch>, --destination=./<repo-name>
```

### `utils/git-raw.sh`

Fetches a single raw file from a GitHub repository at a specific ref.

```bash
bash <(curl https://suede.sh/utils/git-raw) --repo OWNER/REPO --file PATH [--branch BRANCH] [--commit SHA]
# Defaults: --branch=HEAD
```

## `curl` Flags Reference

- `-f` / `--fail` - Fail silently on HTTP errors
- `-s` / `--silent` - Silent mode
- `-S` / `--show-error` - Show errors even in silent mode
- `-L` / `--location` - Follow redirects
