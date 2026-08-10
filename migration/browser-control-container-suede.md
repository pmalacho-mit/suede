# Migrating `browser-control-container-suede` to suede v2

> Read [the shared notes](./README.md) first for *why* any of this changed.
>
> **Do this before `sweater-vest-suede`.** That repository consumes this one,
> and it reads the manifest you are about to fix. Migrating it first would just
> mean doing it twice.

## Where this repository stands today

Verified against `main@2e43a7f` and `release@221852c`:

```
browser-control-container-suede.programmatic-docker-suede  ->  programmatic-docker-suede-f80591d
programmatic-docker-suede-f80591d/         real folder, .gitrepo @ f80591d
release/                                   published to the release branch
*.test.ts, common.ts, pretest.ts, ...      your test suite, at the root
```

`suede list` already classifies this correctly:

| Kind | Entry | Path | Pin |
| --- | --- | --- | --- |
| release | `browser-control-container-suede.programmatic-docker-suede` | `programmatic-docker-suede-f80591d` | `f80591d` |

and `suede check` passes. **Your `main` branch is already v2-shaped.** The root
entry carries the `$repo.` prefix, the backing folder sits outside `release/`
and has a `.gitrepo`, and the commit-suffixed folder name is fine — v2 keys on
the *entry* name, never on the folder's.

What is wrong is what you **publish**:

| | Today | Must become |
| --- | --- | --- |
| Manifest location | `release/.dependencies/` | `release/.suede/.dependencies/` |
| Record filename | `programmatic-docker-suede.gitrepo` | `browser-control-container-suede.programmatic-docker-suede.gitrepo` |
| Record contents | full `.gitrepo` including `parent` | `remote`, `branch`, `commit` only |

That filename is the bug worth understanding, because it is silent. A manifest
filename **is** the name of the sibling a consumer must create. Your published
`release/` code imports `../browser-control-container-suede.programmatic-docker-suede`,
but your manifest asks consumers for a sibling called
`programmatic-docker-suede`. A consumer who follows your manifest exactly gets
a folder your own code does not import. It works today only because
`sweater-vest-suede` happens to have created *both* names by hand.

Your separator is `.` (TypeScript — the import specifier is a path literal).

---

## 1. Rebuild the `release` branch

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

## 3. Replace the manifest

Remove the old one **explicitly** — `extract` writes the new location but will
not delete a directory it does not own:

```bash
git rm -r release/.dependencies
python3 .suede/core/suede.py extract
```

Confirm the result before continuing:

```bash
ls release/.suede/.dependencies/
# expect exactly:
#   browser-control-container-suede.programmatic-docker-suede.gitrepo
#   package.json

git config -f release/.suede/.dependencies/browser-control-container-suede.programmatic-docker-suede.gitrepo --get subrepo.commit
# expect: f80591d... (the commit your folder actually holds)

git config -f release/.suede/.dependencies/browser-control-container-suede.programmatic-docker-suede.gitrepo --get subrepo.parent
# expect: no output — a shipped pointer carries no local bookkeeping
```

## 4. Record the separator

```bash
mkdir -p .suede/.dependencies
printf '.\n' > .suede/.dependencies/separator
```

## 5. Verify, commit, push

```bash
python3 .suede/core/suede.py list     # one release dependency, as above
python3 .suede/core/suede.py check    # exit 0
python3 .suede/core/suede.py diff     # exit 0 — see the warning below

git add -A && git commit -m "suede v2: migrate to the vendored core and manifest layout"
git push origin main
```

---

## The one thing likely to stop you: `diff`

`suede diff` compares `programmatic-docker-suede-f80591d/` against commit
`f80591d` on its remote and fails if they differ. The publish guard runs the
same check, so if it fails locally it will fail in CI and the `release` branch
will not move.

If it reports divergence, pick one deliberately — do not paper over it:

| Situation | What to do |
| --- | --- |
| The edits were accidental or are no longer needed | `git checkout -- programmatic-docker-suede-f80591d/` |
| The edits belong in the library | `bash programmatic-docker-suede-f80591d/.suede/upstream`, get the PR merged, then re-pin with `git subrepo pull` |
| The edits must ship and cannot be upstreamed | `bash .suede/core/vendor.sh programmatic-docker-suede-f80591d` — moves it inside `release/` so the source ships instead of a pointer, then fix the imports it prints |

Vendoring changes what consumers receive: they get the source and a nested
subrepo rather than a pointer they resolve. That is a real decision, not a
workaround — make it on purpose.

## Stop and ask if

- `check` reports `undeclared-edge` or `missing-edge`. It would mean
  `programmatic-docker-suede` has gained a dependency of its own that you now
  need to declare at your root. The fix is
  `python3 .suede/core/suede.py install --repo pmalacho-mit/<name>`, but
  confirm the extra dependency is expected before adding it.
- The folder name `programmatic-docker-suede-f80591d` no longer matches the
  commit in its `.gitrepo`. The name is cosmetic and v2 ignores it, but a
  mismatch usually means someone pulled without renaming — worth knowing which.

## What you are explicitly not doing

- **Not renaming `programmatic-docker-suede-f80591d`.** v2 classifies on the
  entry name, and the entry is already correct. Renaming the folder would break
  the symlink for no gain.
- Not moving your `*.test.ts` files. Root-level test files are not suede
  dependencies and nothing about v2 touches them.
- Not editing `release/.suede/.dependencies/` by hand after step 3.
