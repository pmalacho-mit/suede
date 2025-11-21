# _suede_: [git-subrepo](https://github.com/ingydotnet/git-subrepo) based dependency management

<sub>git-</sub>***Su***<sub>br</sub>***e***<sub>po based</sub> ***de***<sub>pendency management</sub>

> That's smooth... Like <ins>suede</ins>.
> 
> — <cite><em><strong>You,</strong> hopefully</em> (after using this workflow)</cite>

A workflow that relies on [git-subrepo](https://github.com/ingydotnet/git-subrepo) for project dependency management, especially when the dependency is a codebase you manage. 

Not convinced? Jump down to [why](#why).

## Stack

In addition to [git](https://git-scm.com/)...

- [git-subrepo](https://github.com/ingydotnet/git-subrepo): Enables us to more easily include git repositories as project dependencies (as compared to [git submodules](https://www.atlassian.com/git/tutorials/git-submodule) and/or [subtrees](https://www.atlassian.com/git/tutorials/git-subtree))  
- [github actions](https://github.com/features/actions): Enables us to keep our remote subrepo dependency branches (`main` and `release`) up to date with each other. See more about branch structure in [anatomy of a dependency](#dependency).

It is also highly ***recommended*** to use:
- [devcontainers](https://containers.dev/): Enables us to easily spin up a development environment that has [git-subrepo installed as a feature](https://github.com/pmalacho-mit/devcontainer-features/tree/main/src/git-subrepo).

## Workflow

### Consuming a Dependency

1. Confirm that your environment has the `git subrepo` command available. If not, see [instructions on installing git-subrepo](#install-git-subrepo).

```bash
git subrepo --version
```

2. Use the `git subrepo clone` command to clone the `release` branch of your dependency repository into a location of your choosing.

```bash
git subrepo clone --branch release <repo URL> <destination>
```

> For example: `git subrepo clone --branch release git@github.com:my-username/my-repo.git ./my-dependency`

3. From here, you are in control of how your dependency's source code is included in your project. Consider:
   - Using symlinks:
   - Create a typescript alias:

#### Upgrading (i.e. `pull`ing)

To get the latest changes for your dependency, simply run the `git subrepo pull` command, with the final argument being the location of your dependency.

```
git subrepo pull <path-to-dependency>
```

> For example: `git subrepo pull ./my-dependency`
 
#### Modifying (i.e. `push`ing)

Since this workflow treats your dependencies as source code within your project, you can freely modify a dependency's files, and track those changes in your top-level project's history (i.e., with the normal `git add` / `git commit` workflow).

If you then want to make those changes available to all consumers of the dependency, you can simply run the `git subrepo push` command, with the final argument being the location of your dependency.

```
git subrepo push <path-to-dependency>
```

> For example: `git subrepo push ./my-dependency`

This will do two things:

1. <u>Immediately</u> make your changes available to any consumer that follows the [upgrading instructions](#upgrading-ie-pulling)
2. Kick off the [subrepo-pull-into-main](https://github.com/pmalacho-mit/subrepo-dependency-management/blob/main/templates/release/.github/workflows/subrepo-pull-into-main.yml) github action, which will create a pull request of your changes into the `main` branch. That way, your changes can be easily reviewed, tested, adjusted, and/or rolled-back, if necessary. See more in [maintaing a dependency](#maintaing-a-dependency).

> **NOTE:** Because these changes are immediately available, any large and/or breaking changes should instead be accomplished via the [maintaing a dependency](#maintaing-a-dependency) guidance.

### Creating a Dependency

Follow the below steps when setting up a codebase that will behave as a dependency for one or more "consumer" projects.

1. Create your repository using the [suede-dependency-template](https://github.com/pmalacho-mit/suede-dependency-template) as a [template repository](https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-repository-from-a-template) by selecting _Use this template ▼ > Create a new repository_
> <img width="769" height="55" alt="Screenshot 2025-11-20 at 7 30 54 PM" src="https://github.com/user-attachments/assets/f7b698ff-7ddd-4fbd-949f-249aab59f7c2" />

> [!IMPORTANT]  
> On the next screen, you <ins>**must**</ins> toggle on _Include all branches_
>
> <img width="553" height="192" alt="Screenshot 2025-11-20 at 7 29 07 PM" src="https://github.com/user-attachments/assets/daf502e5-43c2-42e1-84e1-503be4acc64a" />
2. Once your repository is created from the template, its [`README.md`](https://github.com/pmalacho-mit/suede-dependency-template/blob/main/README.md) will instruct you on next steps, which include:
   - Enabling certain github action workflow permissions
   - Dispatching the [initialization workflow](https://github.com/pmalacho-mit/suede-dependency-template/blob/main/.github/workflows/initialize.yml)
3. Once you complete the setup steps, your repository can now be distributed as a suede dependency. The [initialization workflow](https://github.com/pmalacho-mit/suede-dependency-template/blob/main/.github/workflows/initialize.yml) will automatically update your repo's `README.md` to instruct users on how to install your dependency, which will follow the format:
   > `git subrepo clone --branch release <repo URL> <destination>`

### Maintaing a Dependency

... todo ...

... maintain codebase as normal, with `main` acting as your primary development source. `./release` folder is where all code that is to be distributed should go (but nothing else!). In this way, the `main` branch acts as the development / testbed for developing your code. The [subrepo-push-release action](https://github.com/pmalacho-mit/suede-dependency-template/blob/main/.github/workflows/subrepo-push-release.yml) handles updating the code on your `release` branch with whatever state of code is in the `./relase` folder at the time of the push to `main` (NOTE: This will also create a push to `main` updating the commit that your `./release/.gitrepo` file references, so it might be necessary to do a pull before pushing again to `main`). 

### Dependencies of Dependencies

... todo ...

... the [subrepo-push-release action](https://github.com/pmalacho-mit/suede-dependency-template/blob/main/.github/workflows/subrepo-push-release.yml) automatically looks at the following files to determine and [populate dependencies](https://github.com/pmalacho-mit/suede/blob/main/scripts/populate-dependencies.sh)

- any `*/.subrepo` files at the root of your project (so top level folders with .subrepo file). In this way, it's a convention to place suede dependencies of your codebase in the root of your project and import them simply by using the local path. Then the action will take all of the `.subrepo` files, and place them into the `.dependencies` folder on the release branch, named as `folder-name.subrepo`. That way you can then easily install the same version of that dependency (especially/automated by using [this script](https://github.com/pmalacho-mit/suede/blob/main/scripts/add-subrepo-dependency.sh))
- any `"dependencies"` listed in your root level package.json will be copied to `.dependencies/package.json` on the release branch
- the `requirements.txt` file at the root of your repo will be copied to `.dependencies/requirements.txt` on the release branch

### Converting an Existing Repository to a Dependency

## Prequisites

### Install [git-subrepo](https://github.com/ingydotnet/git-subrepo) 

#### Within a devcontainer (***RECOMMENDED***) 

Use a [devcontainer](https://containers.dev/) with a `.devcontainer/devcontainer.json` file that includes [git-subrepo as a feature](https://github.com/pmalacho-mit/devcontainer-features/tree/main/src/git-subrepo). 

If you haven't worked with devcontainers before, checkout this [tutorial](https://code.visualstudio.com/docs/devcontainers/tutorial).

##### Initializing a repository with `git subrepo` devcontainer support

Copy the contents of [this file]() to `.devcontainer/devcontainer.json` or create your repository using [git-subrepo-devcontainer-template](https://github.com/pmalacho-mit/git-subrepo-devcontainer-template) as a [template repository](https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-repository-from-a-template) by selecting _Use this template ▼ > Create a new repository_
> <img width="815" height="62" alt="Screenshot 2025-11-20 at 7 30 13 PM" src="https://github.com/user-attachments/assets/212d33a2-e16b-4c49-b4e7-ed21a1e4363b" />


#### On your system

Install `git subrepo` on your system according to their [installation instructions](https://github.com/ingydotnet/git-subrepo?tab=readme-ov-file#installation).

## Why

... todo ...
