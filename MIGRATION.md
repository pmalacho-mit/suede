# Migrating a repository to suede v3

v3 removes the Python installer and everything it did for you: closure
resolution, conflict options, npm and pip merging, the stored separator, and
the prefixed-folder layout. What replaces it is described in
[INSTALL.md](./INSTALL.md) and
[DEPENDENCIES-OF-DEPENDENCIES.md](./DEPENDENCIES-OF-DEPENDENCIES.md); this
document is only the steps. Copy it into a repository as `MIGRATION.md` and
work through it.

What changes on disk, in one table:

| v2, or an early v3 | v3 |
| --- | --- |
| release dependency = real folder `app.widget/` (v2) or symlink `app.widget -> widget` (early v3) | real folder `widget/` plus symlink `widget.app -> widget` |
| edge symlink `widget.mixin -> ./app.mixin` | edge symlink `mixin.widget -> mixin` |
| `.suede/.dependencies/separator` at the root | gone; `--sep` on the install command, or rename the symlink |
| `release/.suede/.dependencies/{package.json,requirements.txt}` | gone; `release/` carries its own `package.json` as a workspace |
| `python3 <(curl …/suede) check|list|extract|diff` | `bash .suede/core/{list,extract,diff}.sh`, `bash <dep>/.suede/core/deps.sh` |
| `.suede/core/vendor.sh` | `git mv <folder> release/<name>` and `git rm` the symlink |

Every symlink now reads **what it is, then who needs it**: `widget.app` is
widget, needed by app. With `suede.`-named repositories your own prefix is
dropped, so `suede.svelte-testing-utility` declares
`suede.typescript-testing-utility.svelte-testing-utility`, and the Python
`suede__wsfs` declares `suede__sqlmodel_utils__wsfs`.

The **records** (`release/.suede/.dependencies/<entry>.gitrepo`) keep their
format but are named after the declaring symlink, so their names flip when a
dependency republishes, and so do the sibling paths its `release/` code
imports. That is why order matters below. A v3 consumer can still install a
not-yet-migrated dependency: `deps.sh` uses whatever names its records carry,
and the installer fetches `deps.sh` from `https://suede.sh/deps` for one that
ships none.

---

## Order

1. **Dependencies before their consumers**, leaves first. A v1-published
   dependency keeps its records at `release/.dependencies/`, which v3 does not
   read, so its consumers cannot resolve its siblings until it republishes.
2. **Each dependency: Part A**, then push. CI republishes.
3. **Each consumer: Part B**, once everything it installs has republished.

A repository that is both (a dependency with dependencies) does Part A, which
includes the consumer steps for its own installs.

## Preconditions

```bash
git subrepo --version    # 0.4.9
git status               # clean; commit or stash first
```

Python is no longer needed by anything.

---

## Part A — a dependency repository (on `main`)

### A1. Which shape?

```bash
ls -d .suede/core release/.suede/core 2>/dev/null   # both present: v2 or early v3 (go to A3)
ls -d release/.dependencies 2>/dev/null             # present: v1 (start at A2)
```

### A2. v1 only: get onto the subrepo layout

A v1 repository vendors nothing from the library. Rewire both branches so the
workflows and cores are subrepos that `sync.sh` can update from then on.
`release` first, because `main` pulls from it.

```bash
git switch release && git pull
git rm -r .github/workflows && git commit -m "suede v3: remove the old workflows"
git subrepo clone https://github.com/pmalacho-mit/suede.git .github/workflows --branch=dependency/release/workflows
git push origin release

git switch main && git pull
git subrepo pull release
git rm -r .github/workflows && git commit -m "suede v3: remove the old workflows"
git subrepo clone https://github.com/pmalacho-mit/suede.git .github/workflows --branch=dependency/main/workflows
git rm .github/workflows/initialize.yml && git commit -m "suede v3: drop the one-shot initialize workflow"
git subrepo clone https://github.com/pmalacho-mit/suede.git .suede/core --branch=dependency/main/core
git subrepo clone https://github.com/pmalacho-mit/suede.git release/.suede/core --branch=dependency/release/core
git rm -r release/.dependencies && git commit -m "suede v3: drop the v1 records"
```

The consumer-facing core is cloned on `main`, **inside `release/`**, and reaches
the `release` branch when `main` publishes. Nothing ever needs `release` checked
out again. If your README still links `suede.sh/install-release`, point it at
`suede.sh/install/release`.

### A3. Update the vendored machinery

```bash
bash .suede/core/sync.sh
```

This pulls `.suede/core` (now `extract.sh`, `list.sh`, `diff.sh`, `lib.sh`,
`push-release.sh`; `suede` and `vendor.sh` are gone), `release/.suede/core`
(now with `deps.sh`), and both workflow folders (no Python setup). It repairs
the `parent` problems template-created repositories have and clears the
leftovers that would block the next publish. If it reports a conflict, follow
what it prints.

### A4. Convert the layout

This works from either starting point: v2's real folders `<repo>.<name>/`, or
the early-v3 symlinks `<repo>.<name> -> <name>`. It does three things and
leaves the fourth to `deps.sh`:

1. Each declaration becomes the folder `<name>/` plus `<name><sep><repo>`,
   keeping the separator it had and dropping your `suede.` prefix when the
   dependency has one.
2. Every other symlink pointing at an installed dependency — the edges — is
   removed. Their names come from each dependency's published records, which
   are about to change, so they are recreated rather than renamed.
3. Your `release/` imports are rewritten from the old declaration names to the
   new ones.
4. You run each dependency's `deps.sh` and paste the `ln -s` lines it prints.

Run it from the root with a clean tree:

```bash
repo="$(basename "$(git remote get-url origin)" .git)"
case "$repo" in suede.?*) short="${repo#suede.}" ;; suede__?*) short="${repo#suede__}" ;; *) short="$repo" ;; esac
map="$(mktemp)"                                   # old name <TAB> new name

# 1. Declarations
for entry in "$repo".* "$repo"__*; do
  [[ -e "$entry" || -L "$entry" ]] || continue
  if [[ "$entry" == "$repo"__* ]]; then sep="__"; else sep="."; fi
  if [[ -L "$entry" ]]; then                       # early v3: a symlink
    folder="$(readlink "$entry")"; folder="${folder#./}"
    rm "$entry"
  elif [[ -f "$entry/.gitrepo" ]]; then            # v2: the real folder
    folder="${entry#"$repo$sep"}"
    mv "$entry" "$folder"
  else
    continue
  fi
  case "$folder" in suede.?*|suede__?*) who="$short" ;; *) who="$repo" ;; esac
  ln -s "$folder" "$folder$sep$who"
  printf '%s\t%s\n' "$entry" "$folder$sep$who" >> "$map"
done

# 2. Edges: symlinks to an install, or to a v2 declaration folder renamed above.
#    Any other symlink of yours is left alone.
for link in *; do
  [[ -L "$link" ]] || continue
  cut -f2 "$map" | grep -qxF -- "$link" && continue          # declared in step 1
  target="$(readlink "$link")"; target="${target#./}"
  if [[ -f "$link/.gitrepo" ]] || cut -f1 "$map" | grep -qxF -- "$target"; then rm "$link"; fi
done

# 3. Imports in release/ - longest names first, so one is never a prefix of another
sort -t$'\t' -k1,1 -r "$map" | while IFS=$'\t' read -r old new; do
  grep -rlF --exclude-dir=.suede -- "$old" release | while IFS= read -r file; do
    sed -i.bak "s#${old//./\\.}#$new#g" "$file" && rm "$file.bak"
  done
done
cat "$map"                                         # what was renamed
```

Review `git diff release/` — every changed line should be an import moving
from `<repo>.<name>` to `<name>.<repo>`. Then recreate the edges:

```bash
for d in */; do
  d="${d%/}"
  [[ "$d" != release && ! -L "$d" && -f "$d/.suede/core/deps.sh" ]] && bash "$d/.suede/core/deps.sh"
done
```

Run the `ln -s` lines it prints (and any install it asks for), and re-run until
each says `everything is in place`. A dependency that has republished under v3
asks for `mixin.widget`; one that has not still asks for its old names, and
gets them — the next time it republishes, re-run this loop.

A **v2 `--dev` or `--vendor` install named after its edge**
(`sweater-vest-suede.dockview-svelte-suede/` as a real folder) is a
development dependency under an odd name, or a vendored one, and both still
read that way. Rename it to the dependency's own name if you prefer; nothing
keys on it.

Remove what v3 does not use:

```bash
git rm -q .suede/.dependencies/separator 2>/dev/null || true
git rm -rq .dependencies 2>/dev/null || true          # an even older location
```

### A5. Third-party packages

v2 published your root `package.json`'s `dependencies` for consumers to merge.
v3 publishes nothing; `release/` is a package. Give it one, seeded from what
the old generated file listed if that helps:

```bash
cat release/.suede/.dependencies/package.json 2>/dev/null   # what v2 published
```

Write `release/package.json` with a `name`, `"private": true`, `"type":
"module"` as appropriate, and the `dependencies` that code under `release/`
imports. Then make it a workspace of the repository:

```jsonc
// package.json, at the root
{ "workspaces": ["release"] }
```

and `npm install`. Packages that only tests or examples need stay in the root
`package.json`. For Python, a `release/pyproject.toml` installed with
`pip install -e ./release` plays the same role.

### A6. Regenerate, check, publish

```bash
bash .suede/core/extract.sh                        # rewrites the records; removes package.json etc.
bash .suede/core/list.sh                           # every dependency with its kind
bash .suede/core/diff.sh                           # exit 0: every pointer is honest
bash release/.suede/core/deps.sh --check --in release   # exit 0: everything declared is in place
git add -A && git commit -m "suede v3: folder-plus-symlink layout, records only"
git push origin main
```

The push touches `release/`, so `subrepo-push-release` runs: the same `diff.sh`
and `deps.sh --check` guard the publish, and if either fires the run summary
says why and the `release` branch is left alone.

If `list.sh` shows something as `development` that you meant to publish, its
symlink is missing or misnamed; `ln -s` fixes it. If `deps.sh --check` names a
missing sibling, run it without `--check` for the commands.

---

## Part B — a consumer (an application, or a dependency's own installs)

Do this after everything you install has republished under v3. Two routes; the
first is faster whenever it applies.

### B1. Clean reinstall (nothing to lose)

If you have not edited any installed dependency —

```bash
for d in */; do [[ -f "$d/.gitrepo" ]] && bash "$d/.suede/core/diff" --quiet >/dev/null 2>&1 || echo "edited: $d"; done
```

prints nothing — the fastest path is to remove and reinstall:

```bash
# remove every install and every symlink at the root (adjust if you keep them elsewhere)
for e in *; do
  if [[ -L "$e" ]]; then git rm -q "$e"
  elif [[ -f "$e/.gitrepo" && "$e" != release ]]; then git rm -rq "$e"; fi
done
git commit -m "suede v3: remove v2 installs"

# install each dependency you actually import, and follow each recipe
bash <(curl -fsSL https://suede.sh/install/release) --repo OWNER/REPO
```

The installer prints the whole recipe — every transitive install and every
`ln -s` — before you commit. Paste it, re-run `<dep>/.suede/core/deps.sh` to see
`everything is in place`, then commit.

### B2. In place (you have local edits to keep)

Sync each top-level dependency to its republished release so you have its
`deps.sh`, then run [A4](#a4-convert-the-layout) as written — it handles an
application the same way:

```bash
bash app.widget/.suede/core/sync       # per dependency, before A4; needs a clean tree
```

In an **application** (no `release/.gitrepo`) the `<name>.<repo>` symlinks A4
creates declare nothing, and step 3 finds no `release/` to rewrite; delete those
symlinks if you prefer a tidy root. The edges `deps.sh` recreates are what
matter.

### B3. Workspaces

Add each installed dependency to your root `package.json` and install once:

```jsonc
{ "workspaces": ["widget", "mixin", "gadget"] }   // real folders, not the symlinks
```

```bash
npm install
```

Your own `package.json` keeps only what your own code imports. Anything v2
merged in on behalf of a dependency can come out; its `release/package.json`
now carries it.

---

## Stop and ask if

- `sync.sh` or `git subrepo pull` reports a conflict it did not resolve.
  Resolve it in the worktree it names; do not force past it.
- `diff.sh` reports divergence on a dependency you did not knowingly edit. Look
  at `bash <dep>/.suede/core/diff` before choosing between revert, upstream and
  vendor.
- A record under `release/.suede/.dependencies/` names an entry you do not
  recognise. `extract.sh` writes exactly the declared entries, so that record
  came from a symlink at your root; `list.sh` shows which.

## What you are never doing

- Editing `release/.suede/.dependencies/` by hand. It is generated on every
  publish.
- Checking out `release` to update the core that ships to consumers. That is
  `bash .suede/core/sync.sh`, on `main`.
- Moving the declaring symlink anywhere other than beside the folder it points
  at, or beside `release/`.
