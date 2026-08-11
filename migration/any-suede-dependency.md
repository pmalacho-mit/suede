# Migrating any suede repository to v2

The general procedure. Copy this file into a repository as `MIGRATION.md` and
work through it; it covers every shape a suede repository is currently in.
[`README.md`](./README.md) explains *what* changed and why — read it once, not
once per repo.

Three things to get right, in this order: **which shape this repo is**, **when
it can be migrated relative to the others**, and **the steps for that shape**.

---

## Step 0 — Which shape is this repository?

Run these four checks at the repo root on `main`:

```bash
ls -d .suede/core                    # A: does the vendored core exist?
ls -d release                        # B: is this a dependency at all?
ls -d release/.dependencies          # C: legacy manifest?
ls -d release/.suede/.dependencies   # D: current manifest?
```

| A `.suede/core` | B `release/` | Shape | Path |
| --- | --- | --- | --- |
| absent | present | **1 — pre-upgrade dependency** | the subrepo layout *and* the v2 changes |
| present | present | **2 — upgraded dependency** | the v2 changes only |
| — | absent | **3 — consumer** | nothing to publish; only the tree matters |

Most repositories that have never run
[`scripts/upgrade/v1.md`](../scripts/upgrade/v1.md) are shape 1. A repository
that has is shape 2, and its migration is much shorter.

`ls -d .dependencies` at the *root* is worth running too: an early layout put
the manifest there. It is dead in every version and should be deleted.

---

## Step 1 — Migration order

**A dependency must be migrated before anything that consumes it.** Its
manifest is what tells a consumer which siblings to create, and until it
republishes, that manifest names siblings its own code does not import.

To find what a repository consumes, look at its root entries:

```bash
python3 <(curl -fsSL https://suede.sh/suede) list
```

Anything in the `release` row is a dependency of this repo, so migrate that
repository first. Work bottom-up: leaves (nothing in the `release` rows) first,
then their consumers, then theirs.

Nothing breaks if you get the order wrong — the installer reports a stale
manifest rather than acting on it — but you would migrate the consumer twice.

For a whole estate, this prints each repo's dependencies without cloning
anything:

```bash
for repo in repo-a repo-b repo-c; do
  echo "== $repo"
  git ls-remote --heads "https://github.com/OWNER/$repo" release >/dev/null 2>&1 \
    || { echo "   (not a published suede dependency)"; continue; }
  git archive --remote "https://github.com/OWNER/$repo" release .dependencies 2>/dev/null \
    | tar -t 2>/dev/null | grep '\.gitrepo$' || echo "   (no suede dependencies)"
done
```

Not every host supports `git archive --remote`; a shallow clone and `ls` is the
reliable fallback.

---

## Step 2 — Preconditions

```bash
python3 --version        # 3.9 or newer
git subrepo --version    # 0.4.9
git status               # clean; commit or stash first
```

If you have added your own files to `.github/workflows`, copy them somewhere
safe — the steps below replace that whole folder.

---

## Step 3 — The steps for your shape

### Shape 1 — pre-upgrade dependency

Both branches get rewired so the workflows and core scripts are vendored from
this library, and can be updated by pulling rather than by editing.

```bash
# release branch first: main pulls from the rebuilt release
git switch release && git pull
git rm -r .github/workflows && git commit -m "suede v2: remove the old workflows"
git subrepo clone https://github.com/pmalacho-mit/suede.git .github/workflows --branch=dependency/release/workflows
git subrepo clone https://github.com/pmalacho-mit/suede.git .suede/core --branch=dependency/release/core
git push origin release

# then main
git switch main
git subrepo pull release
git rm -r .github/workflows && git commit -m "suede v2: remove the old workflows"
git subrepo clone https://github.com/pmalacho-mit/suede.git .github/workflows --branch=dependency/main/workflows
git rm .github/workflows/initialize.yml && git commit -m "suede v2: drop the one-shot initialize workflow"
git subrepo clone https://github.com/pmalacho-mit/suede.git .suede/core --branch=dependency/main/core
```

`initialize.yml` runs once at repository creation; leaving it risks re-running
it. Now continue with **Step 4**.

### Shape 2 — already on the subrepo layout

You only need the newer core scripts and the manifest change:

```bash
git switch main && git pull
git subrepo pull .suede/core
git subrepo pull .github/workflows
git rm .github/workflows/initialize.yml 2>/dev/null && git commit -m "suede v2: drop the one-shot initialize workflow" || true

git switch release && git pull
git subrepo pull .suede/core
git subrepo pull .github/workflows
git push origin release
git switch main && git subrepo pull release
```

Then **Step 4**.

### Shape 3 — a consumer, not a dependency

A repository with no `release/` publishes nothing, so `extract` is a no-op and
there is no manifest of its own. Skip to **Step 5** and just verify the tree.
If `check` reports `undeclared-edge`, install what it names.

---

## Step 4 — Replace the manifest

`extract` writes the current location; it will not delete a directory it does
not own, so remove the old ones explicitly:

```bash
git rm -r release/.dependencies 2>/dev/null || true   # legacy location
git rm -r .dependencies 2>/dev/null || true           # even older, at the root
bash .suede/core/suede extract
ls release/.suede/.dependencies/
```

Expect **one `.gitrepo` per release dependency, named after its root entry**,
plus `package.json` and/or `requirements.txt` if you have them. If a dependency
you expected is missing, `suede list` will say why — its root entry is not
`$repo$SEP`-prefixed, or does not resolve to a folder with a `.gitrepo`.

Spot-check one record:

```bash
git config -f release/.suede/.dependencies/<entry>.gitrepo --get subrepo.commit  # the commit you hold
git config -f release/.suede/.dependencies/<entry>.gitrepo --get subrepo.parent  # no output: correct
```

`parent` is a SHA in *your* repository — meaningless downstream — so a shipped
record must not carry one.

---

## Step 5 — Record the separator

The separator joins your repo name to a dependency's in a root entry name, and
it must be legal inside a module identifier in the language that does the
importing:

| Your `release/` code is mostly | Separator | Because |
| --- | --- | --- |
| `.ts .tsx .js .svelte .vue .css .go .sh .c` | `.` | the import specifier is a path literal |
| `.py .rs .rb` | `__` | a path segment surfaces as an identifier, and `import app.dep` parses as package + submodule |

```bash
mkdir -p .suede/.dependencies
printf '.\n' > .suede/.dependencies/separator     # or __
```

This file lives at the project root and is **never** copied into `release/`: a
consumer's separator is their own choice.

---

## Step 6 — Verify, commit, push

```bash
bash .suede/core/suede list     # what the tree means now
bash .suede/core/suede check    # exit 0, no FAIL lines
bash .suede/core/suede diff     # exit 0 — every pointer is honest

git add -A && git commit -m "suede v2: migrate to the vendored core and manifest layout"
git push origin main
```

The push touches `release/`, which fires `subrepo-push-release`. Open the run:
the same `diff` and `check` run there as a guard, and if either fires the run
summary names the dependency and the reason, and the `release` branch is left
untouched.

---

## Reading the output

`list` classifies every subrepo in the tree:

| Kind | Means |
| --- | --- |
| `release` | announced by a root entry `$repo$SEP<name>`; ships as a pointer |
| `development` | no such root entry; the `release` branch never sees it |
| `vendored` | lives inside `release/`; ships as source |

suede's own plumbing — `.suede/core` and `.github/workflows` — is deliberately
**not** listed. Those are subrepos too, but they are how a dependency gets its
workflows, not something it depends on.

`.suede/devcontainers-suede` normally shows as `development`, and that is
correct: your devcontainer config is not part of what you publish.

## Findings and what to do about them

| Finding | Means | Fix |
| --- | --- | --- |
| `undeclared-edge` **FAIL** | a dependency's dependency is satisfied by something no root entry declares | `suede install --repo OWNER/NAME` to declare it at your root |
| `missing-edge` **FAIL** | a dependency asks for a sibling that does not exist | same |
| `dangling-entry` **WARN** | a `$repo$SEP`-named entry that does not resolve, or has no `.gitrepo` | finish the install, or delete the leftover entry |
| `case-collision` **WARN** | two entries differing only by case | rename one; they are the same file on macOS and two on Linux CI |
| `pin-differs` / `remote-differs` **INFO** | you resolved a dependency's edge to a different commit or remote than it asked for | nothing — you own the resolution. Confirm it is deliberate |
| `diff` reports divergence | a release dependency no longer matches its pinned commit | revert, upstream via `<dep>/.suede/upstream`, or `vendor.sh` it so the source ships |
| "publishes its manifest at the pre-2.0 path" | that dependency has not been migrated | migrate it first |

## Stop and ask if

- `git subrepo clone` refuses because the tree is dirty. Commit or stash; do not
  force past it.
- `list` classifies something as `development` that you expected to publish.
  Its root entry is missing or not prefixed. Renaming the entry flips the
  classification — no files move, but your `release/` imports need the matching
  rename.
- `check` names a transitive dependency you did not know about. Declaring it is
  a real change to what you ship; confirm it is expected before adding it.
- The `release` branch has commits you do not recognise. It is generated from
  `main`, so anything else arrived by hand or from a consumer's `subrepo push`.

## What you are never doing

- Editing `release/.suede/.dependencies/` by hand. It is generated, and CI
  regenerates it on every publish.
- Copying `.suede/.dependencies/separator` into `release/`.
- Renaming a backing folder to match its entry. Classification keys on the
  **entry** name; the folder can be called anything and live anywhere outside
  `release/`.
