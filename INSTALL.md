# Install Infrastructure — Spec

> Companion to [`DEPENDENCIES-OF-DEPENDENCIES.md`](./DEPENDENCIES-OF-DEPENDENCIES.md), which defines *what a dependency is*. This defines *how one gets installed*. Implementation sequencing lives in [`PLAN.md`](./PLAN.md).

---

## 0. Settled decisions

| # | Decision | Rationale |
| --- | --- | --- |
| 1 | Classification matches `$repo` **plus a separator**, not a bare prefix | `suede-extras/` must not be promoted in a repo named `suede` |
| 2 | `$SEP` stored at `.suede/.dependencies/separator` (project root, never shipped) | A consumer's separator is their own choice; shipping it would imply otherwise |
| 3 | Install materializes via **degit + hand-written `.gitrepo`**; git-subrepo is for sync only | Verified working; keeps all installs in one commit; `--commit` stays optional |
| 4 | The CI invariant is **structural, not identity-based** | Consumers may resolve to any remote or commit they choose |
| 5 | `--target` is supported, **use at your own risk**; edge entries written in both locations | Flat-at-root is the safe default; relocation is a real need with real hazards |
| 6 | Install stages by default; `--commit` is opt-in | Confirmed safe — a stale-but-ancestral `parent` still pulls cleanly |
| 7 | Single dependency-free **Python 3.9** file | Consumers can read and patch it; that is the whole point |

---

## 1. Vocabulary

| Term | Definition |
| --- | --- |
| **`$repo`** | Name of the current repository, without owner |
| **`$SEP`** | Separator between `$repo` and a dependency name |
| **Pin** | `(remote, branch, commit)`. `branch` is always `release`. Two pins are *identical* iff remote and commit both match; *conflicting* iff remote matches and commit doesn't |
| **Install** | A real directory containing a `.gitrepo`. Realizes exactly one pin |
| **Entry** | A named filesystem entry (folder **or** symlink) satisfying a dependency reference |
| **Edge** | `(dependent, entry-name, pin)`, read from `<dependent>/.suede/.dependencies/<entry-name>.gitrepo` |
| **Manifest** | A dependency's `.suede/.dependencies/` directory |
| **Closure** | All pins reachable from the root manifest, transitively |
| **World** | The complete scan result: installs, entries, edges, context |

**The filesystem is the lockfile.** No state file. Every planning decision comes from scanning the working tree, so a hand-edited tree is always authoritative.

---

## 2. Ownership and naming

**The root owns the bytes; dependents get links.** One real install per distinct pin, named `$repo$SEP<name>`, at the repo root. Every dependent edge `<dependent>$SEP<name>` is a relative symlink to it. Full rationale in the design doc.

**The separator belongs to the dependent.** `X$SEP Y` is read by `X`'s source, whose imports contain the literal `../X$SEP Y`. So:

| You need | Read it from |
| --- | --- |
| A dependent's required entry name | The manifest **filename**, verbatim — never parsed or split |
| A dependency's own name (to build `$repo$SEP<name>`) | The **`remote`** field inside the `.gitrepo`, basename, `.git` stripped |

`--separator` and inference govern only the project's own entries. Precedence: flag → `.suede/.dependencies/separator` → majority of existing entries → extension inference over `git ls-files` → `.`.

**Collisions.** A conflicting pin kept alongside an existing one gets `$repo$SEP<name>-<short7>`. **Never rename an existing entry** — the project's own imports of `../app.C` are invisible to the installer. The bare name means "first installed."

---

## 3. Install algorithm

**Stage → plan → announce → confirm → apply → verify.** Nothing touches the working tree until the plan is confirmed.

### Phase 0 — Context and preconditions

- `cd "$(git rev-parse --show-toplevel)"`.
- Resolve `$repo`: `--repo-name` → `$SUEDE_REPO_NAME` → `origin` remote basename → toplevel directory name. **Warn loudly when the last two disagree.**
- Resolve `$SEP`.
- **Hard precondition: `git rev-parse --verify HEAD` must succeed.** On an unborn HEAD, `parent` is written empty, install *appears to succeed*, and the first `pull` fails much later with `refusing to merge unrelated histories`. Fail fast with "commit something first."
- Warn (don't fail) on a dirty tree: install works dirty, but `git subrepo pull` does not.

### Phase 1 — Inventory → `World`

- **installs** — every directory containing `.gitrepo`, excluding `.git/` and anything inside `release/` (vendored code can't satisfy an edge).
- **entries** — root entries matching `^$repo$SEP` or `^<installed-name><sep>`, with resolved targets.
- **edges** — every `*.gitrepo` in every install's manifest.

### Phase 2 — Stage

For each unsatisfied pin, `git clone --depth 1 --branch release <remote>` into `.git/suede-cache/<short-sha>/` and read its manifest from there.

Staging under `.git/` means the cache is never accidentally committed, and — the point — **the planner can read a dependency's manifest before installing it**, which is what makes a complete, honest announce block possible.

### Phase 3 — Plan (pure)

| Pin situation | Plan |
| --- | --- |
| Existing install, identical pin | **reuse** |
| Existing install, conflicting pin | **conflict** → §4 |
| No existing install | **install** at `$repo$SEP<name>` |

| Edge situation | Plan |
| --- | --- |
| Sibling resolves to the right install | **ok** |
| Sibling resolves elsewhere | **conflict** → §4 |
| Sibling missing | **link** |
| Dependent's manifest names a different remote than the root's declaration | **override** — announce, do not prompt |

Then plan the flattening entry `$repo$SEP<name>` for every pin in the closure. Cycle safety comes from a visited-pin set; `A → B → A` must be a test case, not an assumption.

### Phase 4 — Announce and confirm

Print the plan. `--dry-run` stops here; `--plan-json` emits it machine-readably.

> **Prompt from `/dev/tty`, never stdin.** The current `install/release.sh` pipes manifest content into the installer's stdin, so a prompt reading stdin will hang or misfire.

### Phase 5 — Apply

Order: real installs → symlinks → manifest records → `git add`.

Write `parent = $(git rev-parse --verify HEAD)` into each new `.gitrepo`. Confirmed safe: `parent` must resolve to a real ancestor but need **not** be the direct parent, so unrelated commits landing between install and commit are fine.

Maintain a **journal** of created paths. On failure, remove exactly those paths — `git checkout -- .` would destroy unrelated work.

### Phase 6 — Verify

Run `check` against the resulting tree. A failure here is a bug in apply.

---

## 4. Conflicts

| Resolution | Result | Risk |
| --- | --- | --- |
| **Coexist** | Two installs, `$repo$SEP C` and `$repo$SEP C-<short7>`; each edge keeps its pin | ⚠ Two runtime copies — breaks singletons, `instanceof`, shared context. Fails at runtime, not install |
| **Unify** | One install; both edges point at it | ⚠ One dependent now runs against an untested commit |
| **Defer** | Nothing installed for the conflicting edge; exit non-zero | — |

Determine "newer" with `git merge-base --is-ancestor` and report the actual relationship (*ancestor* / *diverged*), never a date comparison.

**When the top-level project is a claimant**, unifying changes what its own source compiles against, and the installer cannot see its imports. Default the suggestion to **coexist** and say why.

**Non-interactive policy:** `--on-conflict=coexist|unify-newest|defer`, defaulting to **defer** when stdin isn't a TTY. Silent version selection in CI is not a feature.

### Sample prompt

```
CONFLICT  dockview-svelte-suede is wanted at two commits

    4f10c2a   required by sweater-vest-suede
    9c3e11b   required by serialized-renderer-suede

  4f10c2a is an ancestor of 9c3e11b (17 commits behind).

  1) Coexist          two installs, each dependent keeps its own pin
                      → my-app.dockview-svelte-suede           @ 4f10c2a
                      → my-app.dockview-svelte-suede-9c3e11b   @ 9c3e11b
                      ⚠  two runtime copies — breaks singletons / instanceof

  2) Unify at 9c3e11b ⚠  sweater-vest-suede was built and tested against 4f10c2a
  3) Unify at 4f10c2a ⚠  serialized-renderer-suede was built against 9c3e11b
  4) Defer            install nothing here; print what's needed

  [1-4]
```

Each option states its concrete filesystem outcome and its specific risk. Nothing is preselected.

---

## 5. Announce output

```
suede install — pmalacho-mit/sweater-vest-suede

  repo:       my-app
  separator:  .          (inferred: 41 of 63 tracked files are .ts)
  layout:     flat (repo root)
  commit:     staged only (pass --commit to commit)

PLAN

  install   my-app.sweater-vest-suede            @ 86abeeb   ↓ 1.2 MB
  install   my-app.dockview-svelte-suede         @ 4f10c2a   ↓ 840 KB   (required by sweater-vest-suede)
  reuse     my-app.mixin-suede                   @ 9bb0e41              (already present)

  link      sweater-vest-suede.dockview-svelte-suede  → ./my-app.dockview-svelte-suede
  link      sweater-vest-suede.mixin-suede            → ./my-app.mixin-suede

  override  sweater-vest-suede.mixin-suede pins 3ac9f00; you declare 9bb0e41

  record    2 new entries in release/.suede/.dependencies/
  npm       svelte@^5.41.0                            (new)
  npm       html-to-image@^1.11.13                    (new)
  pip       SQLModel[async] >= 0.0.14                 (new)

Proceed? [Y/n/d(etails)]
```

---

## 6. `check` — what does and doesn't fail

| # | Comparison | Verdict |
| --- | --- | --- |
| 1 | A dependency's local files vs **its own recorded commit** | **FAIL** — your pointer is dishonest |
| 2 | Your pin vs **what a dependent's manifest asked for** | **INFO** — you took ownership |
| 3 | An edge satisfied by a directory **not declared as a release dependency of `$repo`** | **FAIL** — implicit dependency |
| 4 | Root entries matching `$repo$SEP` that don't resolve or lack `.gitrepo` | **WARN** — dangling |
| 5 | Case-only entry collisions | **WARN** — passes on macOS, breaks on Linux CI |

**Check 3, the declaration invariant, stated precisely:**

> For every entry `N.gitrepo` in every release dependency `D`'s manifest, the sibling `N` must exist, and the directory it resolves to must be the backing folder of some root entry `$repo$SEP X`.

It compares no remotes and no commits. It asserts only that a resolution *was declared*, which is what frees check 2 to be informational.

---

## 7. CLI surface

```
suede install --repo OWNER/REPO [options]
suede install --gitrepo <path|->  [options]

  --name <entry>              override the derived entry name
  --separator <str>           override $SEP for this project's own entries
  --repo-name <name>          override $repo detection

  --target <path>             relocate the real install (use at your own risk)
  --link-mode symlink|copy    how edge entries are materialized; default symlink

  --on-conflict coexist|unify-newest|defer   default: ask (tty) / defer (non-tty)

  --no-npm                    do not merge package.json dependencies
  --no-python                 do not merge requirements.txt dependencies
  --allow-conflicting-packages   install where a dependency's npm or python
                              versions disagree with your own, keeping yours

  --dry-run                   plan and announce, change nothing
  --plan-json                 emit the plan as JSON
  --yes                       accept the plan
  --commit                    commit the result

suede check   [--plan-json]
suede list    [--json]        entry → remote@commit, classification, resolved target
suede remove  <entry>         drop an entry; report newly-orphaned ones, never delete
suede extract                 write release/.suede/.dependencies/ (used by the action)
```

`list` is worth building early — classification is implicit in naming, and a one-command view of what the tree means is the cheapest fix for that.

---

## 8. Removal

Flattening creates orphans: remove `B` and `C` stays declared, possibly unreferenced. `remove` recomputes the closure and **reports** newly-unreferenced entries. Never auto-delete — the project may have started importing `C` directly, and no tool here can see imports.

---

## 9. Third-party packages (npm and PyPI)

Same flattening principle, and the two ecosystems work identically. `install` merges a dependency's `.suede/.dependencies/package.json` into the consumer's `package.json`, and its `.suede/.dependencies/requirements.txt` into the consumer's `requirements.txt`. Missing packages are added; lockfiles are never touched.

Requirements are keyed by the **PEP 503 normalized name** (`Foo_Bar` and `foo-bar` are one distribution) and merged as whole lines, so extras and environment markers survive. A published line that names no package — `-r`, `-e`, `--index-url`, a bare URL — is reported as a warning rather than merged or dropped in silence.

**A version you already declare differently is a blocker, not a resolution.** Unifying two ranges is a judgment call about the consumer's code, and the installer cannot see its imports. The refusal names its own way out:

```
BLOCKED

  npm dependency svelte: a dependency asks for ^5.41.0, your package.json declares ^4.0.0.
  python dependency sqlmodel: a dependency asks for sqlmodel>=0.0.14, your requirements.txt declares sqlmodel==0.0.9.
  Unify the versions yourself - suede will not guess - or re-run with
  --allow-conflicting-packages to keep your own declarations and install the rest anyway.
```

`--allow-conflicting-packages` keeps every declaration of the consumer's verbatim, merges everything that does not conflict, and downgrades each conflict to a warning. It is deliberately one flag for both ecosystems: the decision it encodes — *my declarations win* — is the same one either way.

Two **dependencies** disagreeing with each other is a different case and never blocks: neither range is the consumer's, and refusing would leave nothing to reconcile with. The first in pin order is added and the rest are reported.

---

## 10. Sharp edges

- **Two runtime copies under coexist** fail at runtime, not install — the conflict-resolution failure mode people don't anticipate.
- **Case-insensitive filesystems** mask `app.C` / `app.c` collisions on macOS that break on Linux CI.
- **Repo rename** touches every root entry, every `../$repo$SEP*` import in your code *and* every consumer's tree, and every manifest filename. Flattening multiplies the blast radius.
- **`git subrepo pull <symlink>` fails outright** — every subrepo operation must dereference first.
- **`pull` requires a clean tree; install does not.** Any flow that installs then pulls must account for it.
- **Empty-repo inference** has nothing to measure; falling back to `.` is right, but the announce block must say it was a fallback, not a measurement.
