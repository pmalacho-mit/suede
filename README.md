# _Suede_: [git-subrepo](https://github.com/ingydotnet/git-subrepo) based dependency management

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
- [Github Actions](https://github.com/features/actions): Enables us to keep our remote subrepo dependency branches (`main` and `release`) up to date with each other. See more about branch structure in [Anatomy of a Suede Dependency](#anatomy-of-a-suede-dependency).
- [Bash scripts](https://github.com/pmalacho-mit/suede/tree/main/scripts): Automates common tasks like installing dependencies, extracting repository metadata, and downloading specific folders from remote repositories without requiring a full git clone. 
   - For convenience, [suede.sh](https://suede.sh) acts as a proxy for script content, [see more](#suedesh).
 
It is also highly ***recommended*** to use:
- [devcontainers](https://containers.dev/): Enables us to easily spin up a (typically [linux-based](https://mcr.microsoft.com/en-us/artifact/mar/devcontainers/base/about)) development environment that has [git-subrepo installed as a feature](https://github.com/pmalacho-mit/devcontainer-features/tree/main/src/git-subrepo).

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

When you push changes to `main`, the [subrepo-push-release](https://github.com/pmalacho-mit/suede-dependency-template/blob/main/.github/workflows/subrepo-push-release.yml) GitHub Action automatically syncs the contents of `./release/` to the `release` branch.

### `release` Branch

The `release` branch is a clean, distribution-only branch that contains:

- **Only distributable code:** Just the files from the `./release/` folder on `main`
- **`.gitrepo` file:** Tracks the subrepo metadata for consumers who install this dependency

This branch is what consumers actually install. It's kept automatically synchronized with `./release/` on `main` via GitHub Actions, ensuring that the distributed code is always up-to-date.

**Key principle:** Never commit directly to the `release` branch. All changes should flow from `main` → `release` automatically, except for external contributions pushed via `git subrepo push`, which trigger a PR back to `main` for review. See more in [Maintaining a Dependency](#maintaing-a-dependency).

## Workflow

### Consuming a Dependency

To consume a dependency, make use of [./scripts/install-release.sh](./scripts/install-release.sh) and specify the `--repo` flag (or `-r` shortahand) in the form `<repo owner>/<repo name>` (e.g., `pmalacho-mit/suede`).

```bash
bash <(curl https://suede.sh/install-release) --repo <owner/name> 
```

> [!NOTE]  
> The above leverages [`curl`](https://curl.se/), [process substition (`bash <(...)`)](https://tldp.org/LDP/abs/html/process-sub.html), and our [suede.sh script proxy](#suedesh) to download and execute the [install script](./scripts/install-release.sh) in a single, concise line.


<details>
<summary>
See alternative to using <a href="#suedesh">suede.sh</a> script proxy
</summary>

```bash
bash <(curl https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts/install-release.sh) --repo <owner/name> 
```

</details>

The [install script](./scripts/install-release.sh) will inspect the `./release/.gitrepo` file of the dependency's `main` branch to determine the appropriate commit of its `release` branch to install (see more in [Anatomy of a Suede Dependency](#anatomy-of-a-suede-dependency)). 

It then will extract the `release` branch's content (along with the `./release/.gitrepo` file) to a folder named the same as the dendency's repository (or use the `--dest` flag / `-d` shorthand to install the depenency to a different location).

Finally, `git add` & `git commit` the new files.

You then have the dependency's source code [vendored](https://htmx.org/essays/vendoring/) into your repository. You can modify and track changes to it the same as any other code in your repository and only need to amend your typical development workflow when you want to:
- Sync the dependency (see [upgrading](#upgrading-ie-pulling)).
- Publish your local changes upstream (see [modifying](#modifying-ie-pushing)).

#### Upgrading (i.e. `pull`ing)

To get the latest changes for your dependency, first confirm that your environment has the `git subrepo` command available. If not, see [instructions on installing git-subrepo](#install-git-subrepo).

```bash
git subrepo --version
```

Then, simply run the `git subrepo pull` command, with the final argument being the location of your dependency.

```
git subrepo pull <path-to-dependency>
```

> For example: `git subrepo pull ./my-dependency`

This will fetch and merge the newest commits from the dependency’s `release` branch into your subrepo folder.
 
#### Modifying (i.e. `push`ing)

One of the advantages of this workflow is that you can treat your dependency's code as if it were your own source code. If you need to modify the dependency (e.g., fix a bug or add a feature), you can edit the depdency's files directly and test those changes in the context of your project. All such changes will be tracked in your main project's history.

If you then want to make those changes available to all consumers of the dependency (and you have permissions to push to its repository), you can simply run the `git subrepo push` command, with the final argument being the location of your dependency.

```
git subrepo push <path-to-dependency>
```

> For example: `git subrepo push ./my-dependency`

This will push your local changes to the dependency's remote `release` branch, which will trigger the [subrepo-pull-into-main](https://github.com/pmalacho-mit/subrepo-dependency-management/blob/main/templates/dependency/release/.github/workflows/subrepo-pull-into-main.yml) action and the following things will happen:

1. **Immediate revert:** Your changs will immediately be reverted on the remote `release` branch so that any consumer who performs the [upgrading](#upgrading-ie-pulling) instructions won't receive unvetted changes.
> [!WARNING]
> Because your changes are immediately reverted, avoid performing a `git subrepo pull` (i.e., [upgrading](#upgrading-ie-pulling)) until your changes are approved and incorporated. Otherwise, you risk "stomping" over your changes.  
2. **Pull request into main:** A pull request is created into `main` that applies your changes to the `./release/` folder (and are seen by [git-subrepo](https://github.com/ingydotnet/git-subrepo) as happening _"on top"_ of the revert commit in step 1). That way, your changes can be reviewed and tested. See more in [maintaing a dependency](#maintaing-a-dependency).
   - When that PR is approved, your changes will flow back into the `release` branch via the [subrepo-push-release](./templates/dependency/main/.github/workflows/subrepo-push-release.yml) action.

### Creating a Dependency

Follow the below steps when setting up a codebase that will behave as a dependency for one or more "consumer" projects.

1. **Create the repository from the template.** Start by creating a new repository using the [suede-dependency-template](https://github.com/pmalacho-mit/suede-dependency-template) as a [template](https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-repository-from-a-template) (select _Use this template ▼ > Create a new repository_).
> <img width="769" height="55" alt="Screenshot 2025-11-20 at 7 30 54 PM" src="https://github.com/user-attachments/assets/f7b698ff-7ddd-4fbd-949f-249aab59f7c2" />

> [!IMPORTANT]  
> On the next screen, you <ins>**must**</ins> toggle on _Include all branches_. This ensures that you get both the `main` and `release` branches from the template.
>
> <img width="553" height="192" alt="Screenshot 2025-11-20 at 7 29 07 PM" src="https://github.com/user-attachments/assets/daf502e5-43c2-42e1-84e1-503be4acc64a" />
2. **Follow the setup steps in your repository's README.** Once your repository is created from the template, its [`README.md`](https://github.com/pmalacho-mit/suede-dependency-template/blob/main/README.md) will instruct you on next steps, which include:
   - Enabling certain Github Action workflow permissions
   - Dispatching the [initialization workflow](https://github.com/pmalacho-mit/suede-dependency-template/blob/main/.github/workflows/initialize.yml)
3. **Share your dependency.** Once you complete the setup steps, your repository can now be distributed as a suede dependency. The [initialization workflow](https://github.com/pmalacho-mit/suede-dependency-template/blob/main/.github/workflows/initialize.yml) will automatically update your repo's `README.md` to instruct users on how to install your dependency, which will follow the format:
   > `bash <(curl https://suede.sh/install-release) --repo owner/name`

### Maintaing a Dependency

After your dependency repository is set up, you can maintain and develop it as you would any other project, with a few conventions:

- **Use the `main` branch for all development.** Treat the `main` branch as the primary development branch where you add features, fix bugs, and iterate on the code. You can freely edit files on main, commit changes, and create sub-branches for feature development as needed.
- **Keep distributable code in the `./release` folder.** Only the code intended to be consumed by other projects should go in the `./release` directory on `main`. This folder will mirror the content of the release branch. Do not put other files (tests, examples, docs, etc.) inside `./release`.
- **Automatic syncing to the `release` branch.** Whenever you push changes to `main`, the [subrepo-push-release](./templates/dependency/main/.github/workflows/subrepo-push-release.yml) Github Action will automatically update the `release` branch to match the latest state of the code in your `./release` folder. If all goes well, the `release` branch will always contain the up-to-date distributable code after any changes on `main`.
> [!NOTE]  
> The [subrepo-push-release](./templates/dependency/main/.github/workflows/subrepo-push-release.yml) action will also update the reference in your `./release/.gitrepo` file on `main` to point to the new commit on the `release` branch. Therefore, you will need to pull from `main` before pushing further changes.
- **Avoid direct commits to the `release` branch.** Under normal circumstances, you should not need to work on the `release` branch directly. All changes should flow from `main` → `release` via the automated workflow. The only time you'd interact with release manually is if something went wrong and you need to fix merge conflicts (which should be rare).
- **Handle external contributions via PRs.** As mentioned above in the [Modifying section](#modifying-ie-pushing), users that consume your dependency can also push changes to its `release` branch via `git subrepo push ...` (assuming they have write access to your repository). This will trigger the [subrepo-pull-into-main action](./templates/dependency/release/.github/workflows/subrepo-pull-into-main.yml) which will create a pull request to update the content of the `./release` folder on `main` based on their commit to the `release` branch (which will be immediately be reverted, to preserve the state of the remote `release` branch). As a maintainer, you should review these PRs and merge them after appropriate testing. This way, contributions from others get incorporated into your `main` branch (the source of truth) in a controlled manner, and then flow back into `release`.

In summary, do your day-to-day development on `main` (or a sub-branch), keep the `./release` folder up-to-date with the code you want to distribute, and let the automation handle syncing that code to the `release` branch.

### Dependencies of Dependencies

If your suede dependency relies on other libraries or modules, the [subrepo-push-release](./templates/dependency/main/.github/workflows/subrepo-push-release.yml) Github Action will automatically capture these dependencies with the following conventions:

- A `./package.json` file at the root of the `main` branch will have it's [`"dependencies"`](https://docs.npmjs.com/cli/v7/configuring-npm/package-json#dependencies) object copied to `./release/.dependencies/package.json`
   - Therefore, npm packages should be include in [`"dependencies"`](https://docs.npmjs.com/cli/v7/configuring-npm/package-json#dependencies) if and only if they are required by your `release` code. All other dependencies should be installed as [`"devDependencies"`](https://docs.npmjs.com/cli/v7/configuring-npm/package-json#devdependencies).
- Any folders at the root of the `main` branch that contain a `.gitrepo` file (indicating it's a [subrepo](https://github.com/ingydotnet/git-subrepo)) will have the `.gitrepo`  contents copied to `./release/.dependencies/<folder-name>.gitrepo` (e.g., if your `main` branch included `./some-dependency/.gitrepo`, the [subrepo-push-release](./templates/dependency/main/.github/workflows/subrepo-push-release.yml) action will copy it's contents to `./release/.dependencies/some-dependency.gitrepo`)  

These dependencies are then analyzed upon [install](#consuming-a-dependency) and printed to the terminal. 

To see the depenencies of an already installed dependency, run `bash (< https://suede.sh/extract-dependencies)` and provide the dependencies location as a positional argument, for example:

```bash
bash (< https://suede.sh/extract-dependencies) ./example-depepdency/
```

> [!IMPORTANT]  
> The `./release/.dependencies` folder is maintained by the automation and you typically won’t edit it by hand. In fact, as a dependency maintainer, you might not interact with this folder at all — it's generated on the release branch for the benefit of those using your dependency. This intentional manual step for consumers (to review and install sub-dependencies) is seen as a feature: it promotes awareness of exactly what your project is using under the hood, rather than nesting hidden dependencies. It ensures that nothing gets added to a consumer's project without them explicitly opting in.

### Converting an Existing Repository to a Dependency

... todo: ...

... essentially: (1) copy ./.github/workflow/subrepo-push-release.yml of main branch of template to main branch, (2) create release branch as orphan, delete everything, copy over ./.github/workflow/subrepo-pull-into-main.yml and ./.gitingore from release branch of template, (3) on main, do a git subrepo clone of the release branch into the release folder ...

## [suede.sh](https://suede.sh)

[suede.sh](https://suede.sh) is a Cloudflare Worker that provides cached, convenient access to the scripts in this repository. It serves as a proxy to the GitHub raw content URLs, with two key benefits:

1. **Simplified URLs:** Instead of typing the full GitHub raw content URL, you can use shorter URLs like `https://suede.sh/install-release`
2. **Optional file extensions:** The `.sh` extension can be omitted from requests (e.g., `https://suede.sh/utils/degit` instead of `https://suede.sh/utils/degit.sh`)
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
curl https://suede.sh/install-release
```

With:
```bash
curl https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts/install-release.sh
```

The source code for the suede.sh worker is available at [github.com/pmalacho-mit/suede-cloudflare-worker](https://github.com/pmalacho-mit/suede-cloudflare-worker) for review.

## Prequisites

### Install [git-subrepo](https://github.com/ingydotnet/git-subrepo) 

#### Within a devcontainer (***RECOMMENDED***) 

Use a [devcontainer](https://containers.dev/) with a `.devcontainer/devcontainer.json` file that includes [git-subrepo as a feature](https://github.com/pmalacho-mit/devcontainer-features/tree/main/src/git-subrepo). 

If you haven't worked with devcontainers before, checkout this [tutorial](https://code.visualstudio.com/docs/devcontainers/tutorial).

##### Initializing a repository with `git subrepo` devcontainer support

Copy the contents of [this file](https://github.com/pmalacho-mit/git-subrepo-devcontainer-template/blob/main/.devcontainer/devcontainer.json) to `.devcontainer/devcontainer.json` or create your repository using [git-subrepo-devcontainer-template](https://github.com/pmalacho-mit/git-subrepo-devcontainer-template) as a [template repository](https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-repository-from-a-template) by selecting _Use this template ▼ > Create a new repository_
> <img width="815" height="62" alt="Screenshot 2025-11-20 at 7 30 13 PM" src="https://github.com/user-attachments/assets/212d33a2-e16b-4c49-b4e7-ed21a1e4363b" />


#### On your system

Install `git subrepo` on your system according to their [installation instructions](https://github.com/ingydotnet/git-subrepo?tab=readme-ov-file#installation).

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
- Pull updates from the dependency with `git subrepo pull`
- Push your local changes back to the dependency with `git subrepo push`
- Changes flow naturally in both directions without complex merge strategies

**3. Complete Repository State**
- Every commit in your repository contains all the code needed to build and run
- No hidden state in submodule pointers or external dependencies
- `git clone` gives you a working repository immediately, no additional steps
- Full, un-minified source code for all dependencies is present in your repo, making it easy to understand what your project depends on 

**4. Review Process**
- Changes pushed via `git subrepo push` can trigger pull requests for review
- Maintainers can vet changes before they're merged into the dependency's `main` branch
- New installations always use the vetted version from `main`

**5. Clean Separation**
- The two-branch structure keeps development artifacts (tests, examples, docs) separate from distributed code
- Consumers only get what they need, not your entire development environment
- Maintainers work on `main` as usual; automation handles distribution

Suede tries to get the best of both worlds: **vendored dependencies** (complete repository state, no external coordination) with **source control and bidirectional updates** (version tracking, easy syncing, git-based workflows).

## Environment-specific Tips 

... work in progress...

- **Use symlinks or folder references:** If your build or runtime expects dependencies in a certain location (e.g., a libs directory or within node_modules), you can create a symlink from that expected location to the ./my-dependency folder. This way, your project can import/require the dependency as if it were installed normally.
   > [!TIP]
   > Make sure the location of your symlink is not `.gitignore`'d.
- **Use path aliases (for languages like TypeScript):** Many build systems or language toolchains allow you to define alias paths for imports. For example, in a TypeScript project, you could configure tsconfig.json to map an import like `"my-dependency/*"` to your local `./my-dependency/*` (or whichever subdirectory contains the code). This allows you to import the dependency in code using a clean module name, while actually resolving to your vendored subrepo code.

### Vite

### SvelteKit
