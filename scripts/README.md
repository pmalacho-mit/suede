# Scripts

## `extract-subrepo-config.sh`

Parses a git-subrepo `.gitrepo` file from stdin and outputs `OWNER`, `REPO`, and `COMMIT` as `KEY=VALUE` pairs.

```bash
cat .gitrepo | bash <(curl https://suede.sh/extract-subrepo-config)
```

## `install-release.sh`

Fetches a `release/.gitrepo` file from a remote repository and downloads the referenced release archive.

```bash
bash <(curl https://suede.sh/install-release) --repo OWNER/REPO [--branch BRANCH] [--destination DIR]
# Defaults: --branch=main, --destination=./<repo-name>
```

## `install-subrepo-dependency.sh`

Downloads and extracts a repository referenced in a `.gitrepo` file.

```bash
bash <(curl https://suede.sh/install-subrepo-dependency) <file.gitrepo> [--dest DIR]
```

## `populate-dependencies.sh`

```bash
./populate-dependencies.sh
```

> [!NOTE]  
> Used in [subrepo-push-release](../templates/dependency/main/.github/workflows/subrepo-push-release.yml) Github Action

Collects dependency metadata into `release/.dependencies/`: copies `.gitrepo` files from child folders, extracts package.json dependencies, and copies requirements.txt.

### `populate-readme-after-init.sh`

```bash
./populate-readme-after-init.sh
```

> [!NOTE]  
> Used in [initialize](../templates/dependency/main/.github/workflows/initialize.yml) Github Action

Generates installation instructions in README.md by parsing the git remote origin URL.

## `utils/degit.sh`

Downloads a GitHub repository archive at a specific commit/branch without cloning.

```bash
bash <(curl https://suede.sh/utils/degit) --repo OWNER/REPO [--commit SHA] [--branch BRANCH] [--directory DIR] [--include PATH...]
# Defaults: --branch=<default-branch>, --directory=./<repo-name>
```

## `utils/git-raw.sh`

Fetches a single raw file from a GitHub repository at a specific ref.

```bash
bash <(curl https://suede.sh/utils/git-raw) --repo OWNER/REPO --file PATH [--branch BRANCH] [--commit SHA]
# Defaults: --branch=HEAD
```

## curl flags reference

- `-f` / `--fail` - Fail silently on HTTP errors
- `-s` / `--silent` - Silent mode
- `-S` / `--show-error` - Show errors even in silent mode
- `-L` / `--location` - Follow redirects
