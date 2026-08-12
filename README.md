# _Suede_: [git-subrepo](https://github.com/ingydotnet/git-subrepo) based dependency management

<!-- TOKEN-STATUS:START -->
> [!TIP]
> 🟢 The deploy token (`SUEDE_DEPENDENCY_TEMPLATE_PAT`) is good for **87 more days** (2026-11-08).
> _Last checked: 2026-08-12 (UTC)._
<!-- TOKEN-STATUS:END -->

<sub>git-</sub>***Su***<sub>br</sub>***e***<sub>po based</sub> ***de***<sub>pendency management</sub>

> That's smooth... Like <ins>suede</ins>.
> 
> — <cite><em><strong>You,</strong> hopefully</em> (after using this workflow)</cite>

A workflow that relies on [git-subrepo](https://github.com/ingydotnet/git-subrepo) for project dependency management. 

Aims to provide the benefits of vendored dependencies with the power of git-based version control.

Not convinced? Jump down to [why](#why).

## Tech Stack

In addition to [git](https://git-scm.com/)...

- [git-subrepo](https://github.com/ingydotnet/git-subrepo): Enables us to more easily include git repositories as project dependencies (as compared to [git submodules](https://www.atlassian.com/git/tutorials/git-submodule) and/or [subtrees](https://www.atlassian.com/git/tutorials/git-subtree))  
- [Python 3.9+](#python-39-or-newer): The installer is a single dependency-free file, [`scripts/suede.py`](./scripts/suede.py). Everything `install`, `check`, `list`, `diff`, `remove` and `extract` do lives there.
- [Github Actions](https://github.com/features/actions): Enables us to keep our remote subrepo dependency branches (`main` and `release`) up to date with each other. See more about branch structure in [Anatomy of a Suede Dependency](#anatomy-of-a-suede-dependency).
- [Bash scripts](https://github.com/pmalacho-mit/suede/tree/main/scripts): Thin, readable wrappers around the above — the install bootstrap, the publish flow, and the tools a consumer gets inside an installed dependency.
   - For convenience, [suede.sh](https://suede.sh) acts as a proxy for script content, [see more](#suedesh).
 
It is also highly ***recommended*** to use:
- [devcontainers](https://containers.dev/): Enables us to easily spin up a (typically [linux-based](https://mcr.microsoft.com/en-us/artifact/mar/devcontainers/base/about)) development environment that has [git-subrepo installed as a feature](https://github.com/pmalacho-mit/devcontainer-features/tree/main/src/git-subrepo).

## Dependency Registry

| Repo | Description |
| --- | ----------- |
| [pmalacho-mit/dockview-svelte-suede](https://github.com/pmalacho-mit/dockview-svelte-suede) | svelte port of the [dockview](https://dockview.dev/) layout management library |
| [pmalacho-mit/sweater-vest-suede](https://github.com/pmalacho-mit/sweater-vest-suede) | svelte testing library |
| [pmalacho-mit/serialized-renderer-suede](https://github.com/pmalacho-mit/serialized-renderer-suede) | [pixijs](https://pixijs.com/)-based renderer that enables data-driven (as opposed to logic-driven) rendering | 
| [pmalacho-mit/svelte-url-parameterizer-suede](https://github.com/pmalacho-mit/svelte-url-parameterizer-suede) | utility to automatically track svelte runes in the URL bar|
| [pmalacho-mit/with-events-suede](https://github.com/pmalacho-mit/with-events-suede) | |
| [pmalacho-mit/mixin-suede](https://github.com/pmalacho-mit/mixin-suede) | Robust & typesafe mixin library that supports conflict resolution |
| [pmalacho-mit/svelte-snippet-renderer-suede](https://github.com/pmalacho-mit/svelte-snippet-renderer-suede) | Robust mechanism for passing renderable content as props to svelte components |


## Anatomy of a Suede Dependency

A suede dependency repository has a two-branch structure that separates development from distribution:

### `main` Branch

The `main` branch serves as the primary development branch where all work happens. It contains:

- **Source code:** All development files, tests, documentation, examples, etc.
- **`./release/` folder:** Contains only the distributable code that consumers will actually use. This is the code you want others to depend on, stripped of development-only files.
- **`./release/.gitrepo` file:** A metadata file created by [git-subrepo](https://github.com/ingydotnet/git-subrepo) that tracks the relationship between the `./release` folder on `main` and the `release` branch. It contains:
  - The remote repository URL
  - The branch name (`release`)
  - The commit hash from the `release` branch that the `./release` folder currently reflects
  - Parent commit information for tracking history
- **`./release/.suede/.dependencies/` folder:** The **published manifest** — one `.gitrepo` pointer per [release dependency](#dependencies-of-dependencies), plus a `package.json` and/or `requirements.txt` naming the third-party packages your code needs. It is **generated** by `suede extract` and refreshed on every publish; never edit it by hand.
- **`./.suede/core/` folder:** The maintainer's tools and the scripts CI runs, vendored as a subrepo of this library. Update them with `git subrepo pull .suede/core` rather than by editing them.
- **`./release/.suede/core/` folder:** The consumer-facing tools ([`sync`](./dependency/release/core/sync), [`upstream`](./dependency/release/core/upstream), [`diff`](./dependency/release/core/diff)), vendored *inside* `release/` so they ship with it. They live on `main` like everything else you develop, and reach the `release` branch through it — update them with `git subrepo pull release/.suede/core`, never by checking `release` out.
- **`./.suede/.dependencies/separator` file:** One line recording your project's [separator](#dependencies-of-dependencies). It lives at the root and is **never** copied into `release/` — a consumer's separator is their own choice.

When you push changes to `main`, the [subrepo-push-release](./dependency/main/workflows/subrepo-push-release.yml) GitHub Action automatically syncs the contents of `./release/` to the `release` branch.

### `release` Branch

The `release` branch is a clean, distribution-only branch that contains:

- **Only distributable code:** Just the files from the `./release/` folder on `main`
- **`.gitrepo` file:** Tracks the subrepo metadata for consumers who install this dependency
- **`.suede/core/`:** The consumer-facing tools — [`sync`](./dependency/release/core/sync), [`upstream`](./dependency/release/core/upstream) and [`diff`](./dependency/release/core/diff) — which ship inside the dependency and end up at `<dependency>/.suede/core/` in every consumer's repository.

This branch is what consumers actually install. It's kept automatically synchronized with `./release/` on `main` via GitHub Actions, ensuring that the distributed code is always up-to-date.

**Key principle:** Never commit directly to the `release` branch. All changes flow from `main` → `release` automatically. Contributions from consumers arrive as pull requests against `main`, never as direct writes to `release` — see [Maintaining a Dependency](#maintaining-a-dependency).

## Workflow

### Consuming a Dependency

To consume a dependency, run the install bootstrap and specify the `--repo` flag in the form `<repo owner>/<repo name>` (e.g., `pmalacho-mit/suede`).

```bash
bash <(curl -fsSL https://suede.sh/install/release) --repo <owner/name>
```

> [!IMPORTANT]
> Keep the `-f`. Without it a failed download (a 404 page, a proxy error) is
> handed to `bash` and executed.

> [!NOTE]  
> The above leverages [`curl`](https://curl.se/), [process substition (`bash <(...)`)](https://tldp.org/LDP/abs/html/process-sub.html), and our [suede.sh script proxy](#suedesh) to download and execute the [install script](./scripts/install/release.sh) in a single, concise line.


<details>
<summary>
See alternative to using <a href="#suedesh">suede.sh</a> script proxy
</summary>

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts/install/release.sh) --repo <owner/name>
```

</details>

The one-liner is a bootstrap: it finds a Python 3.9+, downloads
[`scripts/suede.py`](./scripts/suede.py), and runs it. Nothing is installed on
your system, and `git` does all the network access — so private repositories,
SSH keys and credential helpers work with no extra setup.

The installer resolves the dependency's `release` branch, then **its**
dependencies, and so on, and shows you the whole plan before touching anything:

```
PLAN

  install   my-app.sweater-vest-suede            @ 86abeeb   (requested)
  install   my-app.dockview-svelte-suede         @ 4f10c2a   (required by sweater-vest-suede)
  reuse     my-app.mixin-suede                   @ 9bb0e41   (already present)

  link      sweater-vest-suede.dockview-svelte-suede  -> ./my-app.dockview-svelte-suede

Proceed? [Y/n]
```

Everything in the closure is installed once, flat at the repo root, named
`$repo.<dependency>`; each dependent gets a symlink to it. Two dependents
wanting the same dependency at different commits is a **conflict**, and the
installer offers the resolutions rather than picking one. See
[DEPENDENCIES-OF-DEPENDENCIES.md](./DEPENDENCIES-OF-DEPENDENCIES.md) for why,
and [INSTALL.md](./INSTALL.md) for the full algorithm.

Installs are **staged, not committed** — review them, then `git commit`, or
pass `--commit`.

### Third-party packages

A dependency also declares what it needs from npm and PyPI. The installer
merges those declarations into your `package.json` and `requirements.txt` —
adding what is missing, and never touching a lockfile.

A package **you already declare at a different version** stops the install
rather than being resolved silently: unifying two version ranges is a judgment
call about your code, not the installer's. The refusal names the way past it:

```
BLOCKED

  python dependency sqlmodel: a dependency asks for sqlmodel>=0.0.14, your
  requirements.txt declares sqlmodel==0.0.9.
  Unify the versions yourself - suede will not guess - or re-run with
  --allow-conflicting-packages to keep your own declarations and install the
  rest anyway.
```

With `--allow-conflicting-packages`, your declaration is kept verbatim, every
non-conflicting package still merges, and each conflict is reported as a
warning — the dependency now runs against a version it never saw, which is your
call to make. `--no-npm` and `--no-python` skip either merge entirely.

### The other commands

```bash
suede check                 # audit the tree: undeclared, missing and dangling entries
suede list  [--json]        # every dependency, its classification, target and pin
suede diff                  # release dependencies that no longer match their pin
suede remove <entry>        # drop an entry; reports what becomes orphaned, deletes nothing
suede extract               # write release/.suede/.dependencies/ (what the publish flow runs)
```

Inside a suede dependency these are already vendored on `main` — run them as
`bash .suede/core/suede <command>`. In a plain consumer repository there is
nothing to vendor, so reach the same file directly:

```bash
python3 <(curl -fsSL https://suede.sh/suede) check
```

Useful install flags: `--dry-run`, `--plan-json`, `--yes`, `--commit`,
`--on-conflict coexist|unify-newest|defer`, `--allow-conflicting-packages`,
`--no-npm`, `--no-python`, `--separator`, `--target`, `--name`. Exit codes: `0`
success, `2` usage, `3` precondition, `4` unresolved conflict, `5` `check`
found a failure.

You then have the dependency's source code [vendored](https://htmx.org/essays/vendoring/) into your repository. You can modify and track changes to it the same as any other code in your repository and only need to amend your typical development workflow when you want to:
- Sync the dependency (see [upgrading](#upgrading-ie-pulling)).
- Publish your local changes upstream (see [modifying](#modifying-ie-contributing-back)).

#### Upgrading (i.e. `pull`ing)

To get the latest changes for a dependency, first confirm that your environment has the `git subrepo` command available. If not, see [instructions on installing git-subrepo](#install-git-subrepo).

```bash
git subrepo --version
```

Then run the `sync` script that shipped inside the dependency. It takes no target — the dependency it pulls is the one it lives in:

```bash
bash <path-to-dependency>/.suede/core/sync
```

> For example: `bash ./my-app.some-suede/.suede/core/sync`

This fetches and merges the newest commits from the dependency's `release` branch into your subrepo folder and applies them as a single commit.

> [!TIP]
> `sync` is a wrapper around `git subrepo pull` that does two things a bare
> pull will not: it runs from the repository root with a root-relative path, so
> where you are does not matter, and it resolves a symlink to the real folder
> first — `git subrepo pull` on a symlink path fails outright, and the edge
> entries between your dependencies are symlinks by default.
>
> Anything you pass is handed straight to `git subrepo pull`, so
> `bash <path-to-dependency>/.suede/core/sync --force` works as git-subrepo
> documents it.

To see what a sync would bring before running one, ask the dependency:

```bash
bash <path-to-dependency>/.suede/core/diff --sync
```

That compares your copy — local edits and all — against the current tip of the
dependency's `release` branch, names both commits, and says outright when your
pin already *is* the tip. See [reviewing your own changes](#reviewing-your-own-changes)
for the other direction.

> [!IMPORTANT]
> `git subrepo pull` requires a clean working tree, while installing does not.
> If you have just installed something, commit before syncing.

To view the changes that were committed, run:

```bash
git diff HEAD~1 HEAD
```
 
#### Modifying (i.e. contributing back)

One of the advantages of this workflow is that you can treat your dependency's code as if it were your own source code. If you need to modify the dependency (e.g., fix a bug or add a feature), you can edit the dependency's files directly and test those changes in the context of your project. All such changes will be tracked in your main project's history.

##### Reviewing your own changes

Because the dependency's history is not in your repository, `git log` on that folder shows your commits but nothing to compare them against. `diff` fills that in:

```bash
bash <path-to-dependency>/.suede/core/diff
```

It compares the commit your `.gitrepo` pins against your copy as it stands — uncommitted edits and brand-new files included, ignored files and the `.gitrepo` itself excluded. The `+` lines are yours, and they are exactly what `upstream` would propose. Extra arguments go to `git diff`, so `--stat` and `--name-only` work; it exits `0` when there is no difference and `1` when there is.

If you then want to offer those changes back to the dependency, commit them and run the `upstream` script that shipped inside it:

```bash
bash <path-to-dependency>/.suede/core/upstream
```

> The working tree must be clean first — commit the changes you want to send.

What happens next:

1. **Your commits are split out** via `git subrepo` and pushed to a deterministic branch on the dependency's remote: `downstream/<owner>/<repo>-<your-commit>`.
2. **A pull request is opened into `main`** by the [suede-downstream-to-main](./dependency/release/workflows/suede-downstream-to-main.yml) action, which replays your change onto the current release and transplants it under `release/` on top of `main`. Maintainers can test, fix and merge it there. Once merged, it flows back out to `release` through the normal publish path.
3. **Your local state is restored**, so a later sync stays safe.

Each commit becomes its own proposal; re-running on the same commit is a no-op. Pass `-r`/`--remote <name>` to push to a remote other than the one tracked in the dependency's `.gitrepo`.

> [!IMPORTANT]
> The dependency's `release` branch is **never** modified by this flow, so other
> consumers are unaffected by an unreviewed change. For the same reason, do not
> `git subrepo push` onto a dependency's `release` branch directly — that writes
> unvetted code onto the branch everyone installs from.

### Creating a Dependency

Follow the below steps when setting up a codebase that will behave as a dependency for one or more "consumer" projects.

1. **Create the repository from the template.** Start by creating a new repository using the [suede-dependency-template](https://github.com/pmalacho-mit/suede-dependency-template) as a [template](https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-repository-from-a-template) (select _Use this template ▼ > Create a new repository_).
> <img width="769" height="55" alt="Screenshot 2025-11-20 at 7 30 54 PM" src="https://github.com/user-attachments/assets/f7b698ff-7ddd-4fbd-949f-249aab59f7c2" />

> [!IMPORTANT]  
> On the next screen, you <ins>**must**</ins> toggle on _Include all branches_. This ensures that you get both the `main` and `release` branches from the template.
>
> <img width="553" height="192" alt="Screenshot 2025-11-20 at 7 29 07 PM" src="https://github.com/user-attachments/assets/daf502e5-43c2-42e1-84e1-503be4acc64a" />
2. **Follow the setup steps in your repository's README.** Once your repository is created from the template, its [`README.md`](https://github.com/pmalacho-mit/suede-dependency-template/blob/main/README.md) will instruct you on next steps, which include:
   - Enabling certain Github Action workflow permissions
   - Dispatching the [initialization workflow](./dependency/main/workflows/initialize.yml), which vendors `.suede/core` onto both branches, connects `./release` to the `release` branch via git-subrepo, and publishes the first release
> [!TIP]
> [`scripts/create/dependency.sh`](./scripts/create/dependency.sh) does steps 1
> and 2 in one command (it needs an authenticated [`gh`](https://cli.github.com/)):
> `./scripts/create/dependency.sh <name> [public|private] [--org <org>]`

3. **Share your dependency.** Once you complete the setup steps, your repository can now be distributed as a suede dependency. The initialization workflow will automatically update your repo's `README.md` to instruct users on how to install your dependency, which will follow the format:
   > `bash <(curl -fsSL https://suede.sh/install/release) --repo owner/name`

### Maintaining a Dependency

After your dependency repository is set up, you can maintain and develop it as you would any other project, with a few conventions:

- **Use the `main` branch for all development.** Treat the `main` branch as the primary development branch where you add features, fix bugs, and iterate on the code. You can freely edit files on main, commit changes, and create sub-branches for feature development as needed.
- **Keep distributable code in the `./release` folder.** Only the code intended to be consumed by other projects should go in the `./release` directory on `main`. This folder mirrors the content of the `release` branch. Do not put other files (tests, examples, docs, etc.) inside `./release`.
- **Automatic publishing.** Whenever a change under `release/` lands on `main`, the [subrepo-push-release](./dependency/main/workflows/subrepo-push-release.yml) action runs [`.suede/core/push-release.sh`](./dependency/main/core/push-release.sh), which regenerates the manifest, runs the publish **guard**, and then syncs `./release` out to the `release` branch.
> [!NOTE]  
> The publish also updates `./release/.gitrepo` on `main` to point at the new commit on the `release` branch, so pull from `main` before pushing further changes.
- **The guard, and why a publish can be refused.** A [release dependency](#dependencies-of-dependencies) ships as a *pointer*, so before that pointer goes out the guard checks it is honest (`suede diff` — nothing has drifted from its pinned commit) and that nothing is resolved implicitly (`suede check`). If either fires, the reason lands in the job summary and **the `release` branch is not touched**, so consumers stay on the last honest version. Run the same checks locally before you push:
  ```bash
  bash .suede/core/diff.sh     # any release dependency with local modifications
  bash .suede/core/suede check # any implicit or dangling resolution
  ```
  If `diff` reports divergence you have three honest options: revert the changes, [upstream](#modifying-ie-contributing-back) them, or [vendor](#dependencies-of-dependencies) the dependency with `bash .suede/core/vendor.sh <entry>` so the source actually ships.
- **Avoid direct commits to the `release` branch.** All changes flow from `main` → `release` via the automated workflow. The only time you'd interact with `release` manually is if something went wrong and you need to fix merge conflicts (which should be rare).
- **Handle contributions as pull requests.** Consumers propose changes with [`upstream`](#modifying-ie-contributing-back), which opens a PR into `main` without ever touching `release`. Review and merge those as you would any other PR; merging republishes through the normal path.
- **Update the vendored machinery with one command, on `main`.** `.suede/core`, `release/.suede/core`, `.github/workflows` and `release/.github/workflows` are all subrepos of this library. Get fixes by pulling them, never by editing the files in place:
  ```bash
  bash .suede/core/sync.sh
  ```
> [!NOTE]
> There is a reason this is a script rather than four `git subrepo pull`s. The workflow subrepos were cloned into the **template** your repository was created from, and a repository made from a template starts a fresh history — so their recorded `parent` names a commit that does not exist in it, and a plain pull refuses. (They live in the template because an Action is restricted in what it may do to `.github/workflows`.) `sync.sh` repairs the parent and retries. It also clears the leftovers that pulling a subrepo nested inside `release/` leaves behind, which would otherwise stop the next publish. See [`.suede/core`'s README](./dependency/main/core/README.md#syncsh).

In summary, do your day-to-day development on `main` (or a sub-branch), keep the `./release` folder up-to-date with the code you want to distribute, and let the automation handle syncing that code to the `release` branch.

### Dependencies of Dependencies

A suede dependency may itself depend on other suede dependencies. Which kind a
dependency is, is decided entirely by **where it lives and what it is named** —
no config file, no manifest you maintain by hand:

| Kind | How it is announced | What ships |
| --- | --- | --- |
| **Release dependency** | A root entry named `$repo$SEP<dependency>` — a folder, or a symlink to one anywhere outside `release/` | A pointer (`.gitrepo`), not the source |
| **Development dependency** | Any other `.gitrepo` folder outside `release/` | Nothing; the `release` branch never sees it |
| **Vendored release dependency** | It lives *inside* `release/` | The source itself, verbatim |

`$repo` is your repository's name without the owner; `$SEP` is the separator
between it and the dependency's name — `.` where imports are path literals
(TypeScript, Svelte, Go), `__` where a path segment has to be a legal identifier
(Python, Rust). The prefix match includes the separator, so a sibling folder
that merely starts with your repo's name is never promoted by accident.

[DEPENDENCIES-OF-DEPENDENCIES.md](./DEPENDENCIES-OF-DEPENDENCIES.md) is the full
treatment, including why the separator is part of the name match and what to do
when a dependency can no longer stay pristine.

**A project records its whole transitive closure as its own release
dependencies.** If you install `B` and `B` needs `C`, you end up with root
entries for both, and `B` gets a symlink:

```
app.B/                 real folder — B's release bytes
app.C/                 real folder — C's release bytes
B.C          ->        ./app.C     symlink satisfying B's edge
```

Three things fall out of that, and they are why the bookkeeping is worth it: a
manifest is a complete recipe (install each pointer once, flat, done);
recursion becomes a repair path rather than the happy path; and every
dependency in the closure is named in *your* root, so every one is yours to
repoint, fork or unify. `suede check` enforces exactly one structural rule —
that nothing was resolved implicitly — and stays informational about which
commit you chose.

The `release/.suede/.dependencies/` folder is generated by
[`suede extract`](./scripts/suede.py) during the publish. Don't edit it by hand.

### Migrating an Existing Repository

[MIGRATION-V1-V2.md](./MIGRATION-V1-V2.md) is the general procedure — it covers
every shape a repository is currently in (a dependency that predates the
vendored core, one that has it, or a plain consumer), the order to migrate them
in, and the steps for each. Copy it into the repository as `MIGRATION.md` and
work through it.

## [suede.sh](https://suede.sh)

[suede.sh](https://suede.sh) is a Cloudflare Worker that provides cached, convenient access to the scripts in this repository. It serves as a proxy to the GitHub raw content URLs, with two key benefits:

1. **Simplified URLs:** Instead of typing the full GitHub raw content URL, you can use shorter URLs like `https://suede.sh/install/release`
2. **Optional file extensions:** The extension can be omitted from requests (e.g. `https://suede.sh/install/release` instead of `https://suede.sh/install/release.sh`), and `https://suede.sh/suede` serves the installer itself
3. **Caching:** Responses are cached via Cloudflare's CDN for faster access

> [!NOTE]  
> [suede.sh](https://suede.sh) is <ins>**not**</ins> utilized in any [./scripts](./scripts/) or Github Action workflows, and instead the GitHub raw content URLs are used instead.

### Usage

Throughout this documentation, you'll see commands like:

```bash
bash <(curl https://suede.sh/<script-name>)
```

This is equivalent to:

```bash
bash <(curl https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts/<script-name>.sh)
```

### Security Considerations

If you have concerns about executing scripts through a third-party proxy, you can always use the direct GitHub raw content URLs instead. Both approaches fetch the same script content, but the GitHub URL bypasses the suede.sh proxy entirely.

For example, replace:
```bash
curl https://suede.sh/install/release
```

With:
```bash
curl https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts/install/release.sh
```

The source code for the suede.sh worker is available at [github.com/pmalacho-mit/suede-cloudflare-worker](https://github.com/pmalacho-mit/suede-cloudflare-worker) for review.

## Prequisites

### Python 3.9 or newer

The installer is a single dependency-free Python file. macOS ships a suitable
interpreter with the Command Line Tools (`xcode-select --install`); most Linux
distributions have one already. Nothing is installed from PyPI — there are no
runtime dependencies, which is what lets you read
[`scripts/suede.py`](./scripts/suede.py) and patch it if you ever need to.

`git` is required too, and does all the network access, so private
repositories, SSH keys and credential helpers work with no extra setup.

An installed dependency records the **SSH** URL of its remote, so `git subrepo
push` from inside it has a route back upstream — HTTPS password authentication
no longer offers one. What you *publish* records the HTTPS URL instead, so
consumers and CI runners can resolve your dependencies without a key of yours.
Fetching tries SSH first and falls back to HTTPS, and suede treats the two
spellings as one repository, so a tree installed either way plans and checks
identically.

### Install [git-subrepo](https://github.com/ingydotnet/git-subrepo) 

Needed to *sync* dependencies (`pull`, `push`), not to install them — the
installer uses plain `git` only.

#### Within a devcontainer (***RECOMMENDED***) 

Use a [devcontainer](https://containers.dev/) with a `.devcontainer/devcontainer.json` file that includes [git-subrepo as a feature](https://github.com/pmalacho-mit/devcontainer-features/tree/main/src/git-subrepo). 

If you haven't worked with devcontainers before, checkout this [tutorial](https://code.visualstudio.com/docs/devcontainers/tutorial).

##### Initializing a repository with `git subrepo` devcontainer support

Copy the contents of [this file](https://github.com/pmalacho-mit/git-subrepo-devcontainer-template/blob/main/.devcontainer/devcontainer.json) to `.devcontainer/devcontainer.json` or create your repository using [git-subrepo-devcontainer-template](https://github.com/pmalacho-mit/git-subrepo-devcontainer-template) as a [template repository](https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-repository-from-a-template) by selecting _Use this template ▼ > Create a new repository_
> <img width="815" height="62" alt="Screenshot 2025-11-20 at 7 30 13 PM" src="https://github.com/user-attachments/assets/212d33a2-e16b-4c49-b4e7-ed21a1e4363b" />


#### On your system

Install `git subrepo` on your system according to their [installation instructions](https://github.com/ingydotnet/git-subrepo?tab=readme-ov-file#installation).

> [!NOTE]
> git-subrepo is enabled by sourcing its `.rc` from your shell startup file, so
> a script that does not run through your login shell can find it missing even
> though it is installed. If `GIT_SUBREPO_ROOT` is set, [`sync`](./dependency/release/core/sync)
> and [`upstream`](./dependency/release/core/upstream) source
> `$GIT_SUBREPO_ROOT/.rc` themselves rather than failing.

## Why

Managing dependencies for code you control presents unique challenges that traditional package managers aren't designed to solve. Suede addresses these challenges by combining the benefits of vendored dependencies with the power of git-based version control. 

### The Problem with Existing Solutions

**Package Managers (npm, pip, etc.)**: While package managers serve a purpose for stable, third-party dependencies from trusted sources, they're poorly suited for code you control and actively develop (and are increasingly becoming a liability due to supply chain attacks).
- **Opaque dependencies:** Most packages deliver pre-built, minified code that's difficult to inspect or understand. You have to trust (and reason about) black-box code in your project.
- **Supply chain vulnerabilities:** The centralized registry model creates attack vectors, which seem to be exploited more and more.
- **Development friction:** The publish-test-fix-republish cycle adds significant overhead when you're actively maintaining a dependency and need to iterate quickly.
- **Version coordination:** Maintaining perfect version alignment across multiple related projects or a monorepo requires constant attention and manual updates. The technologies developed to support these usecases (especially monorepos) are complex pieces of software, which require their own learning and maintenance. 

**Git Submodules** seem like the natural solution for code you control, but they introduce their own problems:
- **State mismatches:** It's easy to push code that depends on submodule changes without also pushing and updating those submodule references, leading to broken builds for other developers.
- **Branch complexity:** Feature development often requires creating matching branches in both the parent repo and submodule(s), whuch then require carefully coordinating merges.
- **Checkout friction:** New contributors must remember to run `git submodule update --init --recursive`, and the submodules don't automatically update when switching branches.
- **Detached HEAD states:** Submodules frequently end up in detached HEAD state, confusing developers who aren't experts in git.

**Git Subtrees** improve on submodules by embedding dependency code directly into the parent repository, but they make bidirectional updates complex and can pollute your git history.

### The Suede Approach

Suede uses git-subrepo to vendor dependency code directly into your repository while maintaining a clean bidirectional sync with the dependency's source. This gives you:

**1. Simplified Development Workflow**
- Edit dependency code directly in place, just like any other code in your project
- Test changes immediately in the real context where they'll be used
- All changes are tracked in your project's normal git history
- No branch coordination or submodule state management

**2. Bidirectional Updates**
- Pull updates from the dependency with [`sync`](#upgrading-ie-pulling)
- Propose your local changes back to the dependency with [`upstream`](#modifying-ie-contributing-back)
- Changes flow naturally in both directions without complex merge strategies

**3. Complete Repository State**
- Every commit in your repository contains all the code needed to build and run
- No hidden state in submodule pointers or external dependencies
- `git clone` gives you a working repository immediately, no additional steps
- Full, un-minified source code for all dependencies is present in your repo, making it easy to understand what your project depends on 

**4. Review Process**
- Contributions from consumers arrive as pull requests against the dependency's `main` branch
- The consumed `release` branch is never written to directly, so an unreviewed change cannot reach other consumers
- Maintainers vet changes, and a publish is refused outright if a shipped pointer would be dishonest

**5. Clean Separation**
- The two-branch structure keeps development artifacts (tests, examples, docs) separate from distributed code
- Consumers only get what they need, not your entire development environment
- Maintainers work on `main` as usual; automation handles distribution

Suede tries to get the best of both worlds: **vendored dependencies** (complete repository state, no external coordination) with **source control and bidirectional updates** (version tracking, easy syncing, git-based workflows).

<!--
## "Self hosting"

Do you (1) trust [@pmalacho-mit](https://github.com/pmalacho-mit) and (2) have an active line of communication with him? If yes, you can probably just start using the 
-->

## Environment-specific Tips 

... work in progress...

- **Use symlinks or folder references:** If your build or runtime expects dependencies in a certain location (e.g., a libs directory or within node_modules), you can create a symlink from that expected location to the ./my-dependency folder. This way, your project can import/require the dependency as if it were installed normally.
   > [!TIP]
   > Make sure the location of your symlink is not `.gitignore`'d.
- **Use path aliases (for languages like TypeScript):** Many build systems or language toolchains allow you to define alias paths for imports. For example, in a TypeScript project, you could configure tsconfig.json to map an import like `"my-dependency/*"` to your local `./my-dependency/*` (or whichever subdirectory contains the code). This allows you to import the dependency in code using a clean module name, while actually resolving to your vendored subrepo code.
- **Windows:** work inside [WSL 2](https://learn.microsoft.com/en-us/windows/wsl/) with the repository on the Linux filesystem. The edge entries between dependencies are symlinks, and native Windows handles committed symlinks poorly. A devcontainer on Windows already runs on the WSL 2 backend.

### Vite

### SvelteKit



### Deploy token setup & monitoring

This repo pushes to the downstream [suede-dependency-template]() using a personal access token. PATs
expire, so a workflow checks the remaining time and keeps a status banner at the
top of this README up to date.

**One-time setup after you fork:**

1. **Create the token.** GitHub → Settings → Developer settings → Personal
   access tokens → Fine-grained tokens. Scope it to **only the target repo**
   ("Only select repositories") and grant:
   - Contents: **Read and write**
   - Workflows: **Read and write**
   - Metadata: Read-only (GitHub adds this automatically)

2. **Store the token.** Save it as a repository **secret** named `SUEDE_DEPENDENCY_TEMPLATE_PAT`
   (Settings → Secrets and variables → Actions → Secrets).

3. **Record the expiry.** On the token page, copy the expiration date and save
   it as a repository **variable** named `SUEDE_DEPENDENCY_TEMPLATE_PAT_EXPIRY` (same screen, Variables
   tab). Use ISO format `YYYY-MM-DD` (e.g. GitHub's "Tue, Jun 30 2026" becomes
   `2026-06-30`).

That's it. The **Check deploy token expiry** workflow runs on every push to
`main` and weekly, then commits an updated banner to the top of this README:

- 🟢 **TIP** — more than 30 days left
- 🟡 **WARNING** — 30 days or fewer
- 🔴 **CAUTION** — final week, or already expired

**When you rotate the token,** update **both** `SUEDE_DEPENDENCY_TEMPLATE_PAT` (new token) and
`SUEDE_DEPENDENCY_TEMPLATE_PAT_EXPIRY` (new date).

**Banner placement (optional).** By default the banner is prepended to the very
top of the README. To pin it somewhere specific instead — say, under your title
or below a badges row — commit these two markers where you want it, and the
workflow will fill that spot from then on:

```md
<!-- TOKEN-STATUS:START -->
> [!TIP]
> 🟢 The deploy token (`SUEDE_DEPENDENCY_TEMPLATE_PAT`) is good for **87 more days** (2026-11-08).
> _Last checked: 2026-08-12 (UTC)._
<!-- TOKEN-STATUS:END -->
```

The workflow only ever rewrites the lines between those markers, so anything
above or below stays exactly as you left it.
