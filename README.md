# _Suede_: [git-subrepo](https://github.com/ingydotnet/git-subrepo) based dependency management

<sub>git-</sub>***Su***<sub>br</sub>***e***<sub>po based</sub> ***de***<sub>pendency management</sub>

> That's smooth... Like <ins>suede</ins>.
> 
> — <cite><em><strong>You,</strong> hopefully</em> (after using this workflow)</cite>

A workflow that relies on [git-subrepo](https://github.com/ingydotnet/git-subrepo) for project dependency management, especially when the dependency is a codebase you manage. 

Not convinced? Jump down to [why](#why).

## Stack

In addition to [git](https://git-scm.com/)...

- [git-subrepo](https://github.com/ingydotnet/git-subrepo): Enables us to more easily include git repositories as project dependencies (as compared to [git submodules](https://www.atlassian.com/git/tutorials/git-submodule) and/or [subtrees](https://www.atlassian.com/git/tutorials/git-subtree))  
- [Github Actions](https://github.com/features/actions): Enables us to keep our remote subrepo dependency branches (`main` and `release`) up to date with each other. See more about branch structure in [anatomy of a dependency](#dependency).
- [Bash scripts](https://github.com/pmalacho-mit/suede/tree/main/scripts): Automates common tasks like installing dependencies, extracting repository metadata, and downloading specific folders from remote repositories without requiring a full git clone. 
   - For convenience, [suede.sh](https://suede.sh) acts as a proxy for [script content](https://github.com/pmalacho-mit/suede/tree/main/scripts). See more in the [suede.sh subsection](#suedesh).
> [!NOTE]  
> Please submit an issue if you experience any issues with these scripts on your operating system. Also, consider using a [linux-based](https://mcr.microsoft.com/en-us/artifact/mar/devcontainers/base/about) [devcontainer](https://containers.dev/), where these scripts are more easily/regularly tested.

It is also highly ***recommended*** to use:
- [devcontainers](https://containers.dev/): Enables us to easily spin up a (typically [linux-based](https://mcr.microsoft.com/en-us/artifact/mar/devcontainers/base/about)) development environment that has [git-subrepo installed as a feature](https://github.com/pmalacho-mit/devcontainer-features/tree/main/src/git-subrepo).

## Workflow

### Consuming a Dependency

To consume a dependency, you'll make use of the [install-release.sh](./scripts/install-release.sh) script, which is proxied at [suede.sh/install-release](https://suede.sh/install-release) (see more: [suede.sh](#suedesh)).

First, `cd` into your repository and execute the following command:

```bash
bash <(curl --fail --silent --show-error --location https://suede.sh/install-release) --repo <owner/name> 
```

Optionally, you can provide an install destination using the `--dest` flag (or `d` shorthand). Otherwise, the dependency will be written to a folder named the same as its repository.

<details>
<summary>
See alternative to using [suede.sh](https://suede.sh)
</summary>
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts/install-release.sh) --repo <owner/name> 
```
</details>

After the script succeeds, follow its instructions to `git add ...` & `git commit ...` the new dependency folder.

You then have the dependency's source code [vendored](https://htmx.org/essays/vendoring/) in your repository. How you integrate it is up to you and depends on your project’s needs. A couple of common approaches:
   - **Use symlinks or folder references:** If your build or runtime expects dependencies in a certain location (e.g., a libs directory or within node_modules), you can create a symlink from that expected location to the ./my-dependency folder. This way, your project can import/require the dependency as if it were installed normally.
      > [!TIP]
      > Make sure the location of your symlink is not `.gitignore`'d.
   - **Use path aliases (for languages like TypeScript):** Many build systems or language toolchains allow you to define alias paths for imports. For example, in a TypeScript project, you could configure tsconfig.json to map an import like `"my-dependency/*"` to your local `./my-dependency/*` (or whichever subdirectory contains the code). This allows you to import the dependency in code using a clean module name, while actually resolving to your vendored subrepo code.
   - See more in [Environment Specific Tips](#environment-specific-tips)

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

This will fetch and merge the newest commits from the dependency’s release branch into your subrepo folder. 
 
#### Modifying (i.e. `push`ing)

One of the advantages of this workflow is that you can treat your dependency's code as if it were part of your own project while developing. If you need to modify the dependency (e.g., fix a bug or add a feature), you can edit the files in `./my-dependency` directly and test those changes in the context of your project. All such changes will be tracked in your main project's history.

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

> **NOTE:** Because these changes are immediately available, any large and/or breaking changes should instead be accomplished via the [maintaing a dependency](#maintaing-a-dependency) guidance.

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
- **Automatic syncing to the `release` branch.** Whenever you push changes to `main`, the [subrepo-push-release Github Action workflow]() will automatically update the `release` branch to match the latest state of the code in your `./release` folder. If all goes well, the `release` branch will always contain the up-to-date distributable code after any changes on `main`.
   > Note: The [subrepo-push-release action]() will also update the reference in your `./release/.gitrepo` file on `main` to point to the new commit on the `release` branch. Therefore, you will need to pull from `main` before pushing further changes.
- **Avoid direct commits to the release branch.** Under normal circumstances, you should not need to work on the release branch directly. All changes should flow from `main` → `release` via the automated workflow. The only time you'd interact with release manually is if something went wrong and you need to fix merge conflicts (which should be rare).
- **Handle external contributions via PRs.** As mentioned above in the [Modifying section](#modifying-ie-pushing), users that consume your dependency can also push changes to its release branch via `git subrepo push ...` (assuming their account has write access to your repository). This will trigger the [subrepo-pull-into-main action]() which will create a pull request to update the content of the `./release` folder on `main` based on the state of the `release` branch. As a maintainer, you should review these PRs and merge them after appropriate testing. This way, contributions from others get incorporated into your `main` branch (the source of truth) in a controlled manner, even though they've already landed on release.

In summary, do your day-to-day development on `main`, keep the `./release` folder up-to-date with the code you want to distribute, and let the automation handle syncing that code to the `release` branch.

### Dependencies of Dependencies

... todo ...

... the [subrepo-push-release action](https://github.com/pmalacho-mit/suede-dependency-template/blob/main/.github/workflows/subrepo-push-release.yml) automatically looks at the following files to determine and [populate dependencies](https://github.com/pmalacho-mit/suede/blob/main/scripts/populate-dependencies.sh)

- any `*/.subrepo` files at the root of your project (so top level folders with .subrepo file). In this way, it's a convention to place suede dependencies of your codebase in the root of your project and import them simply by using the local path. Then the action will take all of the `.subrepo` files, and place them into the `.dependencies` folder on the release branch, named as `folder-name.subrepo`. That way you can then easily install the same version of that dependency (especially/automated by using [this script](https://github.com/pmalacho-mit/suede/blob/main/scripts/add-subrepo-dependency.sh))
- any `"dependencies"` listed in your root level package.json will be copied to `.dependencies/package.json` on the release branch
- the `requirements.txt` file at the root of your repo will be copied to `.dependencies/requirements.txt` on the release branch

### Converting an Existing Repository to a Dependency

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
curl -fsSL https://suede.sh/install-release
```

With:
```bash
curl -fsSL https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts/install-release.sh
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

... todo ...

If gitsubmodules worked better, we'd just use those! You could imagine a similiar branching structure, where you always install the `release` branch as a submodule. 

But unfortunately they too often get in a state where you push up code that relies on changes made to submodules without updating/pushing the submodule and committing that to your top-level repository, leading to a state where the working code you experienced as a developer is not what is reflected upstream. This is understandable in submodules since it requires extra work, where often you'll want to create a seperate branch in the submodule for your branch in the consuming codebase. Then this also brings in the added complexity of managing multiple related branches across repos. 

This workflow gets rid of those issues, since the state of a repository's committed code is fully tracked in the repository itself. Then using gitsubrepo, we enable git as a tool for receiving continuous updates, and also how we can distribute our changes. 

If local changes can't succesfully be pushed to the dependency, then it's just a manner of resolving git conflicts (not ideal, but a well trotted path). 

In this way, it tries to get the best of both worlds. Vendored dependencies, but also source control and bidirectional updates. 

## Environment-specific Tips 

### Vite

### SvelteKit
