# Migrating `sqlmodel-utils-suede` to suede v2

> Read [the shared notes](./README.md) first for *why* any of this changed.
> This is the easiest of the three: **this repository has no suede
> dependencies**, so nothing here is about the dependency graph. It is a
> workflow and manifest-layout migration only.

## Where this repository stands today

Verified against `main@45b32fb` and `release@c76c25a`:

| | |
| --- | --- |
| Suede dependencies | **none** — `release/.gitrepo` is the only `.gitrepo` in the tree |
| `release/.dependencies/` | absent (nothing was ever published there) |
| `release/.suede/.dependencies/` | absent |
| `.github/workflows/` | `subrepo-push-release.yml` only — the **pre-upgrade** layout |
| `.suede/core/` | absent |
| Language | Python (`*.py`, `requirements.txt`, `pytest.ini`) |

`suede list` reports nothing, and `suede check` passes, because there is
nothing to classify. That will still be true when you are finished. What
changes is the machinery around it.

Two things specific to this repository:

- **Your separator is `__`, not `.`** A dot is unrepresentable in a Python
  import: `import sqlmodel_utils_suede.dep` parses as package + submodule, not
  as a folder named `sqlmodel-utils-suede.dep`. Step 4 writes that down so
  every future install agrees, rather than re-deriving it.
- **You have a `requirements.txt`.** `suede extract` copies it into the
  published manifest, the same way it copies `package.json` dependencies for
  the TypeScript repositories. Consumers see what you need; they decide whether
  to install it.

---

## 1. Rebuild the `release` branch

The release branch's workflows and core scripts become subrepos of this
library, so they can be updated by pulling rather than by editing.

```bash
git switch release && git pull
git rm -r .github/workflows && git commit -m "suede v2: remove the old workflows"
git subrepo clone https://github.com/pmalacho-mit/suede.git .github/workflows --branch=dependency/release/workflows
git subrepo clone https://github.com/pmalacho-mit/suede.git .suede/core --branch=dependency/release/core
git push origin release
```

## 2. Rebuild `main`

```bash
git switch main
git subrepo pull release
git rm -r .github/workflows && git commit -m "suede v2: remove the old workflows"
git subrepo clone https://github.com/pmalacho-mit/suede.git .github/workflows --branch=dependency/main/workflows
git rm .github/workflows/initialize.yml && git commit -m "suede v2: drop the one-shot initialize workflow"
git subrepo clone https://github.com/pmalacho-mit/suede.git .suede/core --branch=dependency/main/core
```

`initialize.yml` runs once at repository creation. Leaving it in place risks
re-running it.

## 3. Publish the manifest

There is no `release/.dependencies/` to remove here, so this is just the first
run of the generator:

```bash
python3 .suede/core/suede.py extract
```

Expect `release/.suede/.dependencies/requirements.txt` and nothing else — no
`.gitrepo` records, because there are no release dependencies.

## 4. Record the separator

```bash
mkdir -p .suede/.dependencies
printf '__\n' > .suede/.dependencies/separator
```

This file lives at the project root and is **never** copied into `release/`: a
consumer's separator is their own choice, and shipping yours would imply
otherwise.

## 5. Verify, commit, push

```bash
python3 .suede/core/suede.py list     # expect: no suede dependencies found
python3 .suede/core/suede.py check    # expect: no problems found, exit 0
python3 .suede/core/suede.py diff     # expect: exit 0 (nothing to compare)

git add -A && git commit -m "suede v2: migrate to the vendored core and manifest layout"
git push origin main
```

The push to `main` touches `release/`, which fires `subrepo-push-release`. Open
the run and confirm it succeeded. It will report the manifest as unchanged
apart from `requirements.txt`.

---

## Stop and ask if

- `git subrepo clone` refuses because the tree is dirty — commit or stash, do
  not `--force` past it.
- `suede list` reports anything at all. It should report nothing; if a
  `.gitrepo` folder has appeared since this document was written, use
  [the sweater-vest document](./sweater-vest-suede.md) as the model for
  handling it rather than improvising.
- The `release` branch has commits you do not recognise. It is generated from
  `main`, so anything else on it was either hand-pushed or came from a
  consumer's `subrepo push`.

## What you are explicitly not doing

- Not renaming anything. There is nothing prefixed to rename.
- Not touching `install.sh`, `tests/`, `pytest.ini` or the Python source.
- Not editing `release/.suede/.dependencies/` by hand, now or ever — it is
  generated, and CI regenerates it on every publish.
