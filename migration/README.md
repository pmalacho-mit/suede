# Migrating a suede dependency to v2

Copy the file for your repository into it (as `MIGRATION.md`), then work
through it. Each one is self-contained and states what that repository looks
like today, so you can tell whether anything drifted before you start.

| Repository | Document | Order |
| --- | --- | --- |
| `sqlmodel-utils-suede` | [sqlmodel-utils-suede.md](./sqlmodel-utils-suede.md) | any time — it depends on nothing |
| `browser-control-container-suede` | [browser-control-container-suede.md](./browser-control-container-suede.md) | **before** sweater-vest |
| `sweater-vest-suede` | [sweater-vest-suede.md](./sweater-vest-suede.md) | **last** |

**The order matters in one direction only.** `sweater-vest-suede` consumes
`browser-control-container-suede`. A dependency's manifest is what tells a
consumer which siblings to create, so migrate the dependency first and the
consumer second. Nothing breaks if you get it wrong — the installer reports a
stale manifest rather than acting on it — but you would have to redo the
consumer.

---

## What actually changed

### 1. The manifest moved, and its filenames changed meaning

| | Before | After |
| --- | --- | --- |
| Location | `release/.dependencies/` | `release/.suede/.dependencies/` |
| Filename | the dependency's own name (`programmatic-docker-suede.gitrepo`) | **the root entry name, verbatim** (`browser-control-container-suede.programmatic-docker-suede.gitrepo`) |
| Contents | a copy of the live `.gitrepo` | only `remote`, `branch`, `commit` |

The filename change is the load-bearing one. A manifest filename is the name of
the sibling a consumer must create, and your `release/` code imports
`../$repo.$dependency`. A manifest saying `programmatic-docker-suede` asks a
consumer for a sibling your own code never imports.

`parent` is dropped from shipped records because it is a SHA in *your*
repository — meaningless, and actively misleading, to anyone resolving your
pointer. `cmdver` is dropped because it records your local git-subrepo version.

You do not do any of this by hand. `suede extract` writes it from the tree, and
CI runs it on every publish.

### 2. Classification now requires the separator

v1 promoted **any** root folder containing a `.gitrepo` to a release
dependency. v2 requires a root entry named `$repo` **plus a separator** —
`.` or `__`. In a repo named `suede`, a sibling folder `suede-extras/` used to
be silently promoted; now it is not.

All three of these repositories already use the prefixed naming, so this costs
you nothing. Run `suede list` to confirm before and after.

### 3. Every transitive dependency is declared at your root

If you depend on `B` and `B` depends on `C`, you declare **both**. `B` gets a
symlink to your copy of `C`:

```
$repo.B/          real folder
$repo.C/          real folder
B.C      ->       ./$repo.C
```

The cost is that your manifest advertises dependencies your own code never
imports. That is intentional: the manifest is a closure, not an import list,
and it means a consumer installs each pointer once, flat, with no resolver.
`suede check` fails on exactly one thing — an edge satisfied by something no
root entry declares — and stays informational about which commit you picked.

### 4. Publishing is now guarded

`.suede/core/push-release.sh` refuses to publish when:

- a release dependency has been modified away from the commit its `.gitrepo`
  names (`suede diff`) — your pointer would be dishonest; or
- an edge is satisfied by something undeclared (`suede check`) — an implicit
  dependency.

Both write the reason into the run summary. Neither touches the `release`
branch when it fires, so a failed publish leaves consumers on the last honest
version.

If a dependency genuinely cannot stay pristine, that is what
`.suede/core/vendor.sh` is for: it moves the dependency inside `release/` so
the source ships instead of a pointer.

### 5. The workflows became callers

The logic moved out of YAML into `.suede/core/*.sh`, vendored from this
library. That is what makes it testable without a runner — and it means your
repository gets fixes by pulling the subrepo rather than by you editing YAML.

`.suede/core/suede.py` is the installer itself, vendored, so the guard runs
with no network beyond git.

---

## Before you start (all repositories)

```bash
python3 --version        # 3.9 or newer
git subrepo --version    # 0.4.9
git status               # clean; commit or stash first
```

If you have added your own workflow files to `.github/workflows`, copy them
somewhere safe: the steps replace that whole folder.

## When you are done

The same three commands answer it, in every repository:

```bash
python3 .suede/core/suede.py list     # what the tree means now
python3 .suede/core/suede.py check    # exit 0, no FAIL lines
python3 .suede/core/suede.py diff     # exit 0 — every pointer is honest
```

Then push `main`. The `subrepo-push-release` workflow republishes `release`
with the new manifest. Check the run summary: if the guard fired, it names the
dependency and the reason.

## If something looks wrong

- **`check` reports `undeclared-edge`.** A dependency of a dependency is not
  declared at your root. Install it: `python3 .suede/core/suede.py install
  --repo <owner/name>`. That is the flattening rule doing its job.
- **`check` reports `missing-edge`.** A dependency asks for a sibling that does
  not exist at all. Same fix.
- **`diff` reports divergence.** Either revert the local changes, upstream them
  with `<dep>/.suede/upstream`, or vendor the dependency.
- **`list` classifies something as `development` that you expected to ship.**
  Its root entry is missing or not `$repo$SEP`-prefixed. Renaming the entry
  flips the classification — no files move, but your `release/` imports need
  the matching rename.
- **The installer warns that a dependency publishes at the pre-2.0 path.** That
  dependency has not been migrated yet. Migrate it first, or accept that its
  own dependencies are described by names that predate the prefix rule.
