# _Suede_: [git-subrepo](https://github.com/ingydotnet/git-subrepo) based dependency management

<sub>git-</sub>***Su***<sub>br</sub>***e***<sub>po based</sub> ***de***<sub>pendency management</sub>

> That's smooth... Like <ins>suede</ins>.
> 
> — <cite><em><strong>You,</strong> hopefully</em> (after using this workflow)</cite>

A workflow that relies on [git-subrepo](https://github.com/ingydotnet/git-subrepo) for project dependency management, especially when the dependency is a codebase you manage. 

Aims to provide the benefits of vendored dependencies with the power of git-based version control.

Not convinced? Jump down to [why](#why).

## Stack

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

- **Only distributable code:** Just the files from the `./release/` folder on `main`—no tests, examples, or development artifacts
- **`.gitrepo` file:** Tracks the subrepo metadata for consumers who install this dependency

This branch is what consumers actually install. It's kept automatically synchronized with `./release/` on `main` via GitHub Actions, ensuring that the distributed code is always up-to-date.

**Key principle:** Never commit directly to the `release` branch. All changes should flow from `main` → `release` automatically, except for external contributions pushed via `git subrepo push`, which trigger a PR back to `main` for review. See more in [Maintaining a Dependency](#maintaing-a-dependency) and [Understanding Direct Pushes to Release](#understanding-direct-pushes-to-release).

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

The [install script](./scripts/install-release.sh) will inspect the `./release/.gitrepo` file of the dependency's `main` branch to determine the appropriate commit of its `release` branch to install (see more in [Anatomy of a Suede Dependency](#anatomy-of-a-suede-dependency)). It then will extract the `release` branch's content (along with the `./release/.gitrepo` file) to a folder named the same as the dendency's repository.

> [!TIP]
> You can optionally provide a destination to the [install script](./scripts/install-release.sh) using the `--dest` flag (or `d` shorthand) to install the depenency to a location other than a folder named the same as it's repository.

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

> [!CAUTION]
> It's important to understand that [direct pushes to `release`](#understanding-direct-pushes-to-release) (as made possible by [modifying](#modifying-ie-pushing) a depndency) can create a situation where the code on your dependency's `release` branch has not been verified in its `main` branch environment. If this a concern to you, please see [mitigation strategies](#mitigation-strategies).
 
#### Modifying (i.e. `push`ing)

One of the advantages of this workflow is that you can treat your dependency's code as if it were part of your own project while developing. If you need to modify the dependency (e.g., fix a bug or add a feature), you can edit the depdency's files directly and test those changes in the context of your project. All such changes will be tracked in your main project's history.

> [!NOTE]  
> It's **recommended** to be mindful when modifying any dependency code, since it might require resolving conflicts down the line if you decide to [pull](#upgrading-ie-pulling). Nevertheless, that process will merely be resolving [merge conflicts](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/addressing-merge-conflicts/resolving-a-merge-conflict-using-the-command-line). 

If you then want to make those changes available to all consumers of the dependency (and you have permissions to push to its repository), you can simply run the `git subrepo push` command, with the final argument being the location of your dependency.

```
git subrepo push <path-to-dependency>
```

> For example: `git subrepo push ./my-dependency`

This will push your local changes to the dependency's remote `release` branch, which does two things:

1. **Immediate availability:** Your changes will be available to any consumer of the dependency that follows the [upgrading instructions](#upgrading-ie-pulling)
2. **Pull request into main:** The [subrepo-pull-into-main](https://github.com/pmalacho-mit/subrepo-dependency-management/blob/main/templates/release/.github/workflows/subrepo-pull-into-main.yml) Github Action will kick off in your dependency's repository, which will create a pull request of your changes into its `main` branch. That way, your changes can be easily reviewed, tested, adjusted, and/or rolled-back, if necessary. See more in [maintaing a dependency](#maintaing-a-dependency).

> **NOTE:** Because these changes are immediately available, any large and/or breaking changes should instead be accomplished via the [maintaing a dependency](#maintaing-a-dependency) guidance. See [Understanding Direct Pushes to Release](#understanding-direct-pushes-to-release) for important details about this workflow.

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
   > `git subrepo clone --branch release <repo URL> <destination>`

### Maintaing a Dependency

After your dependency repository is set up, you can maintain and develop it as you would any other project, with a few conventions:

- **Use the main branch for all development.** Treat the main branch as the primary development branch where you add features, fix bugs, and iterate on the code. You can freely edit files on main, commit changes, and create sub-branches for feature development as needed.
- **Keep distributable code in the `./release` folder.** Only the code intended to be consumed by other projects should go in the `./release` directory on `main`. This folder will mirror the content of the release branch. Do not put other files (tests, examples, docs, etc.) inside `./release`.
- **Automatic syncing to the `release` branch.** Whenever you push changes to `main`, the [subrepo-push-release Github Action workflow](./templates/dependency/main/.github/workflows/subrepo-push-release.yml) will automatically update the `release` branch to match the latest state of the code in your `./release` folder. If all goes well, the `release` branch will always contain the up-to-date distributable code after any changes on `main`.
   > Note: The [subrepo-push-release action](./templates/dependency/main/.github/workflows/subrepo-push-release.yml) will also update the reference in your `./release/.gitrepo` file on `main` to point to the new commit on the `release` branch. Therefore, you will need to pull from `main` before pushing further changes.
- **Avoid direct commits to the release branch.** Under normal circumstances, you should not need to work on the release branch directly. All changes should flow from `main` → `release` via the automated workflow. The only time you'd interact with release manually is if something went wrong and you need to fix merge conflicts (which should be rare).
- **Handle external contributions via PRs.** As mentioned above in the [Modifying section](#modifying-ie-pushing), users that consume your dependency can also push changes to its release branch via `git subrepo push ...` (assuming their account has write access to your repository). This will trigger the [subrepo-pull-into-main action](./templates/dependency/release/.github/workflows/subrepo-pull-into-main.yml) which will create a pull request to update the content of the `./release` folder on `main` based on the state of the `release` branch. As a maintainer, you should review these PRs and merge them after appropriate testing. This way, contributions from others get incorporated into your `main` branch (the source of truth) in a controlled manner, even though they've already landed on release (see more in [Understanding Direct Pushes to `release`](#understanding-direct-pushes-to-release)).

In summary, do your day-to-day development on `main`, keep the `./release` folder up-to-date with the code you want to distribute, and let the automation handle syncing that code to the `release` branch.

### Dependencies of Dependencies

... todo: revise this section for clarity (AI generated) ...

What if your dependency itself relies on other libraries or modules? The suede workflow can handle this scenario by recording those secondary dependencies so that consumers of your project know what additional pieces to install:

- **Sub-dependencies via git-subrepo:** If your dependency  uses one or more other git-subrepo-managed repositories (i.e. you have included other internal libraries as subrepos in your project's `main` branch), it's a convention to place each subrepo at the root of your project (each in its own top-level folder). For each such subrepo, there will be a hidden file (a .gitrepo file) inside that folder to track it. The subrepo-push-release action automatically detects these and creates corresponding records in the release branch under a directory called .dependencies. Specifically, for each root-level subrepo folder, it generates a file named <folder>.subrepo inside .dependencies on the release branch. Each .subrepo file contains the information needed to fetch that dependency (its Git URL, branch, and the exact commit hash). This ensures that if your project has its own dependencies, those can be precisely identified by anyone consuming your project.
- **Package manager dependencies:** Likewise, if your project has dependencies managed via package files (for example, a Node.js library with a package.json listing dependencies, or a Python project with a requirements.txt), the workflow will capture those too. It will copy the contents of the "dependencies" section of your package.json into a file at .dependencies/package.json on the release branch. And for Python, it will copy your requirements.txt to .dependencies/requirements.txt on the release branch.
- **Using the dependency metadata:** The .dependencies directory on the release branch (and mirrored in the `./release` folder on main) serves as a manifest of all secondary dependencies your project needs. As a consumer of this dependency, you should look at .dependencies after adding the subrepo to identify any additional installations needed. For example, if there are .subrepo files listed, you might run a script (like the provided add-subrepo-dependency.sh) to automatically clone those sub-dependencies into your project. Or, if there's a .dependencies/package.json, you might install those NPM packages in your project to satisfy the peer requirements. The key point is that dependencies-of-your-dependency are not automatically pulled in, but all the information about them is available to you in a structured way.

> [!IMPORTANT]  
> The .dependencies folder is maintained by the automation and you typically won’t edit it by hand. In ?fact, as a dependency maintainer, you might not interact with this folder at all — it's generated on the release branch for the benefit of those using your dependency. This intentional manual step for consumers (to review and install sub-dependencies) is seen as a feature: it promotes awareness of exactly what your project is using under the hood, rather than nesting hidden dependencies. It ensures that nothing gets added to a consumer's project without them explicitly opting in.

### Converting an Existing Repository to a Dependency

... todo ...

## Understanding Direct Pushes to Release

When using `git subrepo push` to publish dependency changes, it's important to understand that these changes bypass the normal review process and become immediately available to other users. This section explains how this works and how to manage it.

### The Scenario

When a user follows the [modifying](#modifying-ie-pushing) guidance and pushes changes directly to the `release` branch (via `git subrepo push`), those changes become immediately available to anyone who runs `git subrepo pull` to upgrade their dependency (see more in [Upgrading](#upgrading-ie-pulling)). However, these changes have not yet been vetted or tested in the `main` branch environment and thus bypass the normal development workflow.

This creates a temporary mismatch: the `release` branch contains changes that aren't yet reflected in `./release/` on `main`. The changes won't be incorporated into `main` until the [subrepo-pull-into-main](./templates/dependency/release/.github/workflows/subrepo-pull-into-main.yml) GitHub Action creates a pull request and a maintainer reviews and merges it.

**Important distinction:** Users who _newly install_ the dependency are not affected by this mismatch. The [install script](./scripts/install-release.sh) reads `./release/.gitrepo` on the `main` branch to determine which commit of the `release` branch to install. This ensures new installations use a version that's been vetted through the `main` branch workflow.

### Design Rationale

This behavior is an intentional design decision. The workflow was created to enable rapid iteration on dependencies within the context of the codebases that consume them. By allowing direct pushes to `release` that take effect immediately, developers can:

1. Make a change to a dependency while working in a consumer codebase
2. Test that change in the real-world context where it will be used
3. Push it to `release` to share with other consumers
4. Continue development without waiting for a review cycle (while preserving the ability do a review later on)

This minimizes friction and accelerates the development feedback loop, especially when working across multiple related repositories that you maintain.

### Mitigation Strategies

If you're concerned about unvetted changes reaching users who upgrade their dependencies, you have several options:

1. **Restrict write access:** Only users with write permissions can successfully execute `git subrepo push`. Limit this to trusted maintainers to ensure only reviewed changes reach the `release` branch.

2. **Use the standard workflow for major changes:** For larger or breaking changes, follow the [maintaining a dependency](#maintaing-a-dependency) workflow: make changes on `main` in the `./release/` folder and let the automation sync them to the `release` branch after review.

3. **Check for unvetted changes before upgrading:** Before running `git subrepo pull`, verify that the dependency's `release` branch hasn't diverged from what's reflected in `main`:
   - Compare the commit hash in `./release/.gitrepo` on the `main` branch with the latest commit on the `release` branch
   - Look for open pull requests in the dependency repository with names matching `chore/update-release-*` — these indicate changes on `release` that haven't been reviewed and merged into `main` yet
   - If there's a mismatch or pending PR, wait for the maintainer to review and merge it before upgrading (if you are concerned about using unvetted code).

4. **Communicate with your team:** If you have multiple consumers of a dependency, establish conventions about when to use `git subrepo push` (quick fixes, minor improvements) versus the standard workflow (breaking changes, major features).


## [suede.sh](https://suede.sh)

[suede.sh](https://suede.sh) is a Cloudflare Worker that provides cached, convenient access to the scripts in this repository. It serves as a proxy to the GitHub raw content URLs, with two key benefits:

1. **Simplified URLs:** Instead of typing the full GitHub raw content URL, you can use shorter URLs like `https://suede.sh/install-release`
2. **Optional file extensions:** The `.sh` extension can be omitted from requests (e.g., `https://suede.sh/utils/degit` instead of `https://suede.sh/utils/degit.sh`)
3. **Caching:** Responses are cached via Cloudflare's CDN for faster access

### Usage

Throughout this documentation, you'll see commands like:

```bash
bash <(curl -fsSL https://suede.sh/install-release)
```

This is equivalent to:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts/install-release.sh)
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

**Package Managers (npm, pip, etc.)** work well for stable, third-party dependencies but create friction when you need to:
- Iterate quickly on a dependency while developing a project that uses it
- Test changes in the real context where the dependency will be consumed
- Share local modifications across multiple projects before publishing
- Maintain perfect version alignment across a monorepo or related projects

The publish-test-fix-republish cycle adds significant overhead, especially for dependencies you actively maintain.

**Git Submodules** seem like the natural solution for code you control, but they introduce their own problems:
- **State mismatches:** It's easy to push code that depends on submodule changes without also pushing and updating those submodule references, leading to broken builds for other developers
- **Branch complexity:** Feature development often requires creating matching branches in both the parent repo and submodule(s), then carefully coordinating merges
- **Checkout friction:** New contributors must remember to run `git submodule update --init --recursive`, and the submodules don't automatically update when switching branches
- **Detached HEAD states:** Submodules frequently end up in detached HEAD state, confusing developers who aren't experts in git

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
- Full, un-minified source code for all dependencies is present in your repo, making it easy to understand what your project depends on—especially valuable when using LLMs to help explore and understand your codebase

**4. Optional Review Process**
- Changes pushed via `git subrepo push` can trigger pull requests for review
- Maintainers can vet changes before they're merged into the dependency's main branch
- New installations always use the vetted version from main
- See [Understanding Direct Pushes to Release](#understanding-direct-pushes-to-release) for details

**5. Clean Separation**
- The two-branch structure keeps development artifacts (tests, examples, docs) separate from distributed code
- Consumers only get what they need, not your entire development environment
- Maintainers work on `main` as usual; automation handles distribution

### When to Use Suede

Suede is particularly valuable when you:
- Maintain both the dependency and the code that consumes it
- Need to iterate quickly across multiple related repositories
- Want the benefits of vendoring (complete repo state) without losing version control
- Have a small team with write access and want minimal process overhead
- Need to test dependency changes in real-world contexts before publishing

It's less suitable when:
- You're consuming third-party dependencies you don't maintain (use package managers)
- You need strict version pinning and isolated dependency updates (use package managers)
- Your dependency has a large number of independent consumers who shouldn't get immediate updates (consider traditional releases with semantic versioning)

### The Best of Both Worlds

Suede tries to get the best of both worlds: **vendored dependencies** (complete repository state, no external coordination) with **source control and bidirectional updates** (version tracking, easy syncing, git-based workflows). If local changes can't be successfully pushed to the dependency, it's just a matter of resolving git merge conflicts—not ideal, but a well-understood process that doesn't require learning new tools or managing complex state. 

## Environment-specific Tips 

- **Use symlinks or folder references:** If your build or runtime expects dependencies in a certain location (e.g., a libs directory or within node_modules), you can create a symlink from that expected location to the ./my-dependency folder. This way, your project can import/require the dependency as if it were installed normally.
   > [!TIP]
   > Make sure the location of your symlink is not `.gitignore`'d.
- **Use path aliases (for languages like TypeScript):** Many build systems or language toolchains allow you to define alias paths for imports. For example, in a TypeScript project, you could configure tsconfig.json to map an import like `"my-dependency/*"` to your local `./my-dependency/*` (or whichever subdirectory contains the code). This allows you to import the dependency in code using a clean module name, while actually resolving to your vendored subrepo code.

### Vite

### SvelteKit
