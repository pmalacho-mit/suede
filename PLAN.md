# PLAN.md — Implementing the v2 installer

> Specs: [`DEPENDENCIES-OF-DEPENDENCIES.md`](./DEPENDENCIES-OF-DEPENDENCIES.md) (what a dependency is) and [`INSTALL.md`](./INSTALL.md) (how one gets installed). This is the build order, the file inventory, and the test strategy.

---

## 1. The one architectural decision everything else depends on

**The planner is a pure function. It performs no I/O.**

```python
def plan(world: World, request: Request, policy: Policy,
         manifests: Mapping[Pin, Manifest]) -> Plan: ...
```

`scan()` produces a `World`. `stage()` produces `manifests`. `apply()` consumes a `Plan`. Everything interesting in between — dedup, conflict detection, closure computation, cycle handling, entry naming — is dicts and frozen dataclasses.

This is what makes the hardest logic testable with literals: no git repos, no filesystem, no network, no fixtures. `check()` is pure over `World` for the same reason. If this boundary holds, ~2,000 lines is comfortable. If it leaks, it will not be.

Everything below is downstream of that decision.

---

## 2. File layout inside `scripts/suede.py`

Single file, but sectioned with a strict dependency direction — later sections may import earlier ones, never the reverse.

| § | Section | I/O? | ~Lines |
| --- | --- | --- | --- |
| 1 | Version guard, constants | — | 40 |
| 2 | Errors (`SuedeError`, `Precondition`, `PlanError`) | — | 40 |
| 3 | **Model** — dataclasses | pure | 140 |
| 4 | **Git** — the *only* place `subprocess` appears | I/O | 150 |
| 5 | `.gitrepo` read/write (via `git config -f`) | I/O | 80 |
| 6 | Context — `$repo`, `$SEP`, extension inference | I/O | 150 |
| 7 | `scan()` → `World` | I/O | 180 |
| 8 | `stage()` → `Mapping[Pin, Manifest]` | I/O | 120 |
| 9 | **`plan()`** | **pure** | 250 |
| 10 | Conflict option generation | **pure** | 120 |
| 11 | `announce()`, `plan_json()` | **pure** | 150 |
| 12 | Prompting (`/dev/tty`) | I/O | 90 |
| 13 | `apply()` + journal/rollback | I/O | 200 |
| 14 | `check()` | **pure** | 180 |
| 15 | `list`, `remove`, `extract` | mixed | 160 |
| 16 | CLI | I/O | 130 |

Roughly 1,900 lines, of which ~950 are pure and unit-testable without fixtures.

### Model

```python
from __future__ import annotations          # str | None on 3.9
from dataclasses import dataclass, field
from typing import Optional, Mapping

@dataclass(frozen=True)
class Pin:
    remote: str
    commit: str
    branch: str = "release"
    @property
    def short(self) -> str: return self.commit[:7]
    @property
    def name(self) -> str:                   # dependency identity
        return self.remote.rstrip("/").rsplit("/", 1)[-1].removesuffix(".git")

@dataclass(frozen=True)
class Entry:
    name: str                                # root-level entry name, verbatim
    kind: str                                # "folder" | "symlink" | "dangling"
    target: Optional[str]                    # repo-relative realpath if symlink

@dataclass(frozen=True)
class Install:
    path: str                                # repo-relative real directory
    pin: Pin
    parent: str                              # .gitrepo parent field

@dataclass(frozen=True)
class Edge:
    dependent: str                           # install path of the dependent
    entry_name: str                          # manifest filename, verbatim
    pin: Pin                                 # what the dependent asked for

@dataclass(frozen=True)
class World:
    root: str
    repo: str
    sep: str
    sep_source: str                          # "flag"|"file"|"entries"|"inferred"|"default"
    head: Optional[str]                      # None => unborn HEAD
    dirty: bool
    installs: Mapping[str, Install]          # path -> Install
    entries: Mapping[str, Entry]             # name -> Entry
    edges: tuple[Edge, ...]

# --- plan ---
@dataclass(frozen=True)
class Act:
    op: str          # "install"|"reuse"|"link"|"copy"|"record"|"override"|"npm"
    entry: str
    pin: Optional[Pin] = None
    dest: Optional[str] = None
    target: Optional[str] = None
    reason: str = ""                         # "requested" | "required by X" | "flattening"

@dataclass(frozen=True)
class Claim:
    edge: Optional[Edge]                     # None => the root project itself
    pin: Pin

@dataclass(frozen=True)
class Conflict:
    remote: str
    claims: tuple[Claim, ...]
    ancestry: str                            # "ancestor"|"descendant"|"diverged"|"unknown"
    options: tuple[Act, ...]
    involves_root: bool

@dataclass(frozen=True)
class Plan:
    acts: tuple[Act, ...] = ()
    conflicts: tuple[Conflict, ...] = ()
    warnings: tuple[str, ...] = ()
    blockers: tuple[str, ...] = ()           # non-empty => refuse to apply
```

`ancestry` is computed during `stage()` (it needs git) and passed in, keeping `plan()` pure.

---

## 3. Repo inventory

> Paths below are what is observable from the published repo. Anything marked **verify** should be confirmed against the working tree before acting on it.

### Add

| Path | Purpose |
| --- | --- |
| `scripts/suede.py` | The installer. Everything below is a thin shell around it |
| `dependency/release/core/vendor.sh` | Release dep → vendored (spec'd, not yet written) |
| `dependency/release/core/diff.sh` | Divergence check; the `subrepo-push-release` guard |
| `dependency/release/core/sync.sh` | `git subrepo pull` from any cwd, dereferencing symlinks |
| `.github/workflows/test.yml` | Unit + integration + contract tests, Python matrix |
| `.github/workflows/test-actions.yml` | Containerized workflow tests (§6, tier C) |
| `.tests/unit/` | Pure planner/check tests (`unittest`) |
| `.tests/integration/` | Real-repo tests against generated fixtures |
| `.tests/fixtures/make_graph.py` | Dependency-graph fixture generator |
| `.tests/contract/subrepo-degit-contract.test.sh` | Already written; move here |
| `.tests/actions/docker-compose.yml` | Gitea + act_runner harness |
| `.tests/actions/bootstrap.sh` | Seed the local forge with repos, PAT, secrets |

### Modify

| Path | Change |
| --- | --- |
| `scripts/install/release.sh` | **Gut to a ~40-line bootstrap.** Keep the path — the URL is baked into every dependency README the `initialize` workflow has ever generated. Check `python3 >= 3.9`, download `suede.py`, `exec` it, pass args through |
| `scripts/extract/dependencies.sh` | v1 semantics. Replaced by `suede.py extract` (classification) and the announce block (next-steps printing). Keep as a deprecated shim for one release, or delete outright — **verify** whether anything else calls it |
| `dependency/main/workflows/subrepo-push-release.yml` | Add the `diff` guard and `suede check` **before** the push to `release`. Refactor so the YAML is a thin caller (§6) |
| `dependency/release/workflows/subrepo-pull-into-main.yml` | **verify** path. Refactor to thin caller for testability |
| `sites/suede.sh` (Cloudflare worker) | Currently appends `.sh`. Must also serve `.py` so `https://suede.sh/suede` resolves to `scripts/suede.py`. **This blocks the bootstrap** — do it first |
| `README.md` | Install one-liner unchanged. Add `python3 >= 3.9` to prerequisites; document `check`, `list`, `remove`; replace the v1 "Dependencies of Dependencies" section with a pointer to the design doc |
| `.devcontainer/devcontainer.json` | Ensure python3 and git-subrepo features; add docker-in-docker for the Actions tests |

### Delete (absorbed into `suede.py`)

| Path | Absorbed by |
| --- | --- |
| `scripts/install/gitrepo.sh` | `suede.py install --gitrepo` |
| `scripts/utils/degit.sh` | `git clone --depth 1 --branch release` |
| `scripts/utils/git-raw.sh` | `git cat-file` / sparse checkout |
| `scripts/extract/subrepo-config.sh` | `git config -f <file> subrepo.<key>` |
| `v2.md` | Merged into `DEPENDENCIES-OF-DEPENDENCIES.md` |

> Deleting the `scripts/utils/*` and `scripts/install/gitrepo.sh` endpoints breaks any `https://suede.sh/...` URL a user has copied. Keep them as one-line shims that print a deprecation notice and forward to `suede.py` for at least one release.

### Keep unchanged

`.suede/devcontainers-suede`, `typescript2mermaid-suede`, `package.json`, the deploy-token expiry workflow.

---

## 4. Build order

Each milestone ends with something runnable and tested. No milestone depends on a later one.

**M0 — Worker `.py` support.** One-line change to `sites/suede.sh`, plus a smoke test that `curl https://suede.sh/suede` returns Python. Blocks everything.

**M1 — Model + git layer + scan.** §3–§7. Exit: `suede list` prints a correct classification table for a hand-built fixture tree. This is the cheapest way to validate the classification rule (including the `$repo`+separator fix) against a real tree before any planning exists.

**M2 — `check`.** §14, pure over `World`. Exit: all five checks pass/fail correctly on hand-built trees. Ship this early — it is independently useful, it is what the GitHub Action needs, and it forces `World` to be right.

**M3 — Planner.** §9–§11, pure. Exit: the full scenario matrix (§5.1) passes as unit tests with literal `World`s. No I/O written yet. **This is the milestone worth over-testing.**

**M4 — Stage + apply.** §8, §12, §13. Exit: `install --dry-run` announces correctly against real remotes; `install --yes` produces correct trees; rollback leaves the tree untouched on injected failure.

**M5 — Conflict UX.** Interactive prompting, `/dev/tty`, `--on-conflict`. Exit: each resolution produces the documented tree.

**M6 — `extract`, `remove`, npm merge.**

**M7 — Workflows.** Refactor to thin callers, wire in `diff` + `check`, build the containerized Actions harness (§6).

**M8 — Migration.** Deprecation shims, README, migrate one real dependency (`sweater-vest-suede` → `dockview-svelte-suede` is a genuine two-level case) end to end.

---

## 5. Testing

Five layers, cheapest first. The rule: **push every assertion to the cheapest layer that can hold it.** Anything provable against a literal `World` must not be tested with a git repo.

### 5.1 Layer 1 — Pure unit tests (`unittest`, no fixtures)

Stdlib `unittest`, so `python3 -m unittest discover .tests/unit` works with zero dev dependencies. Fast enough to run on save.

**Planner scenarios — the matrix that must pass:**

| # | Scenario | Expected |
| --- | --- | --- |
| 1 | Single dep, no transitive | 1 install, 1 record |
| 2 | Chain A→B→C | 3 installs at root, 2 links, 3 records |
| 3 | Diamond, same commit | 1 install of C, 2 links, **not** 2 installs |
| 4 | Diamond, different commits | 1 conflict, 3 options, 0 acts |
| 5 | Diamond, conflict, `--on-conflict=coexist` | 2 installs, `C` and `C-<short7>`, each link correct |
| 6 | Diamond, conflict, `unify-newest` | 1 install at the descendant commit |
| 7 | Root project is a claimant | `involves_root=True`, coexist suggested first |
| 8 | Cycle A→B→A | Terminates; each pin installed once |
| 9 | Re-run on a satisfied tree | **Empty plan** (idempotency) |
| 10 | Dependent's manifest names a different remote than root declares | `override` act, **no** conflict |
| 11 | Dependents use different separators (`B__C`, `D.C`) | Both entry names verbatim; one shared install |
| 12 | Two remotes with the same basename | Second gets a disambiguated entry name |
| 13 | Unborn HEAD | `blockers` non-empty; no acts |
| 14 | Existing entry would be renamed | Never renamed; newcomer suffixed |
| 15 | `--target` set | Edge entries planned in **both** locations |

**Check scenarios:**

| # | Tree state | Expected |
| --- | --- | --- |
| 1 | Edge satisfied by an undeclared directory | FAIL (declaration invariant) |
| 2 | Edge satisfied, declared, different commit than asked | INFO only |
| 3 | Edge satisfied, declared, different **remote** | INFO only |
| 4 | Manifest entry with no sibling at all | FAIL |
| 5 | Dangling `$repo$SEP` symlink | WARN |
| 6 | `app.C` and `app.c` both present | WARN |
| 7 | `suede-extras/` in a repo named `suede` | **Not** classified as a release dependency |

**Context scenarios:** separator precedence (all five sources), extension inference with a `.ts`/`.py` mix, inference on an empty repo, `$repo` detection when remote basename and directory disagree, repo names containing dots.

### 5.2 Layer 2 — Integration (real git, generated fixtures)

`.tests/fixtures/make_graph.py` builds a graph of local bare repos from a small spec, so scenarios are declarative:

```python
GRAPH = {
  "dockview": {"deps": {}},
  "sweater":  {"deps": {"sweater.dockview": ("dockview", "HEAD")}},
  "renderer": {"deps": {"renderer.dockview": ("dockview", "HEAD~3")}},   # conflict
}
```

It creates one bare repo per node with a `release` branch and a correct `.suede/.dependencies/`, so the fixture exercises the *real* manifest format rather than a mock.

Tests: run the real CLI end to end and assert the resulting tree shape (entry names, symlink targets, `.gitrepo` contents, manifest contents). Cover each row of §5.1 that has a filesystem consequence, plus:

- **Idempotency:** run twice, second run is a no-op and exits 0.
- **Rollback:** inject a failure mid-apply (patch the git layer to raise on the third clone); assert `git status` is byte-identical to before.
- **Dirty tree:** install succeeds; the warning is printed.
- **`--commit`:** produces exactly one commit containing all installs.

### 5.3 Layer 3 — git-subrepo contract (bash)

[`subrepo-degit-contract.test.sh`](.tests/contract/subrepo-degit-contract.test.sh), already written and green (23/23 against git-subrepo 0.4.9). Pins the degit → subrepo handoff: `parent` semantics, the unborn-HEAD trap, symlink inertness, clean-tree requirements.

Run it in CI against **multiple git-subrepo versions**. It exists to fail loudly when git-subrepo's assumptions change, which is exactly the failure mode nothing else would catch.

### 5.4 Layer 4 — Cross-platform matrix

| Axis | Values |
| --- | --- |
| Python | 3.9, 3.10, 3.11, 3.12, 3.13 |
| OS | `ubuntu-latest`, `macos-latest` |
| git-subrepo | pinned 0.4.9, plus `main` (allowed to fail) |

macOS is not optional: it is the only runner that catches case-insensitive collisions, and it is the platform that sets the 3.9 floor. Add `python3 -m py_compile` under 3.9 specifically as a syntax gate — a version guard inside the file cannot save you from a `SyntaxError`.

### 5.5 Layer 5 — End-to-end migration

One real dependency, installed into a scratch consumer repo, then `check`, then `git subrepo pull`, then `git subrepo push`. Run on a schedule rather than per-commit; it is the only test that exercises real network, real GitHub, and real auth.

---

## 6. Testing the GitHub Actions

### 6.1 The refactor that makes this tractable

Right now the workflows do real work in YAML, which is the least testable place it could live. **Move all logic into scripts and reduce each workflow to a caller:**

```yaml
# dependency/main/workflows/subrepo-push-release.yml
- run: bash .suede/core/push-release.sh
  env:
    SUEDE_TOKEN: ${{ secrets.SUEDE_DEPENDENCY_TEMPLATE_PAT }}
```

Once that holds, ~90% of workflow behaviour — extraction, the divergence guard, `check`, the README status block, the early-return path — is tested at **Layer 2** against local bare repos, with no runner, no container, and no network. What genuinely needs a forge is only: does the trigger fire, do permissions work, does the PAT flow, does the PR get created.

Do this refactor first. Everything in §6.2 and §6.3 gets smaller as a result.

### 6.2 Tier B — `act`, for wiring

`nektos/act` in the dind devcontainer, for workflow syntax, step wiring, conditionals, and env plumbing:

```bash
act push -W .github/workflows/test.yml --container-architecture linux/amd64
act workflow_dispatch -W dependency/main/workflows/subrepo-push-release.yml \
    -s SUEDE_DEPENDENCY_TEMPLATE_PAT=dummy --dryrun
```

Fast, catches YAML and wiring mistakes. **Known limits:** `GITHUB_TOKEN` is not real, cross-repo pushes don't work, and `peter-evans/create-pull-request` will not actually open a PR. Treat `act` as a linter with a runtime, not as fidelity.

### 6.3 Tier C — Gitea + `act_runner` in dind, for the real two-repo flow

The suede workflows are fundamentally **cross-repository and cross-branch**: push to `main` → sync `release`; `subrepo push` to `release` → revert + open a PR into `main`. That needs a forge. Gitea runs Actions via `act_runner` (act under the hood), hosts multiple repos, issues PATs, and runs entirely offline.

`.tests/actions/docker-compose.yml`:

```yaml
services:
  gitea:
    image: gitea/gitea:1.22
    environment:
      GITEA__actions__ENABLED: "true"
      GITEA__security__INSTALL_LOCK: "true"
    ports: ["3000:3000"]
    volumes: ["gitea-data:/data"]

  runner:
    image: gitea/act_runner:latest
    depends_on: [gitea]
    environment:
      GITEA_INSTANCE_URL: "http://gitea:3000"
      GITEA_RUNNER_REGISTRATION_TOKEN: "${RUNNER_TOKEN}"
      CONFIG_FILE: /config.yaml
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./runner-config.yaml:/config.yaml
volumes: { gitea-data: }
```

`bootstrap.sh` then, entirely over the Gitea API:

1. Create an admin user and a PAT (`gitea admin user create`, then `/api/v1/users/{u}/tokens`).
2. Create `test-org/dep-lib` and `test-org/consumer`.
3. Push `main` (with `release/` as a subrepo) and an orphan `release` branch to `dep-lib`.
4. Register the runner, wait for it to appear in `/api/v1/admin/runners`.
5. Set repo secrets and variables through `/api/v1/repos/{o}/{r}/actions/secrets`.

Scenarios worth the setup — each is a trigger-and-assert loop against the API:

| Scenario | Assert |
| --- | --- |
| Push to `dep-lib:main` | `release` branch content matches `release/`; `release/.gitrepo` commit updated |
| Push with a **divergent** release dependency | `release` branch **unchanged**; README status block names the offending dep; run concludes without pushing |
| Push with an **undeclared transitive** dependency | `check` fails; `release` unchanged |
| `git subrepo push` into `dep-lib:release` | Revert commit lands on `release`; PR opened into `main` |
| Consumer installs `dep-lib` | Correct tree; `check` clean |

**Caveats to plan around.** Gitea Actions is act-based, not GitHub — `uses:` clauses resolve against github.com by default, so either allow that egress or vendor the handful of actions you use (`actions/checkout` is the main one) into the test image. Keep the workflows to a small, known set of `uses:` so this stays cheap. And `create-pull-request` behaves differently enough that the PR-creation step is worth extracting into a script with a pluggable "open PR" backend: `gh` on GitHub, the Gitea API in tests.

**Run cadence:** Tier C is slow. Run it on PRs touching `dependency/**` or `.github/workflows/**`, and nightly. Tiers A and B run on every commit.

### 6.4 Tier D — Canary against real GitHub

A scratch org with a real template repo, exercised on a schedule. This is the only thing that catches GitHub-specific behaviour — PAT expiry, `GITHUB_TOKEN` permission defaults, workflow-permission settings, actual `create-pull-request` semantics. Small, slow, and irreplaceable. It is also where the existing deploy-token expiry banner already lives conceptually.

---

## 7. Definition of done

- [ ] `suede.py` compiles under 3.9 and runs on the full OS × Python matrix
- [ ] Every §5.1 scenario is a passing unit test
- [ ] Integration tests cover every scenario with a filesystem consequence, plus idempotency and rollback
- [ ] Contract suite green against pinned and latest git-subrepo
- [ ] Workflows reduced to thin callers; logic covered at Layer 2
- [ ] Tier C harness reproduces all five §6.3 scenarios offline
- [ ] Deprecation shims in place for every removed `suede.sh` endpoint
- [ ] One real dependency migrated end to end
- [ ] `DEPENDENCIES-OF-DEPENDENCIES.md`, `INSTALL.md`, and `README.md` agree with the implementation

---

## 8. Sequencing risks

- **The worker `.py` change (M0) blocks the bootstrap.** Do it first; it is a one-liner and a smoke test.
- **`extract/dependencies.sh` may have callers you don't expect** — grep the workflows and the template repo before deleting.
- **The `initialize` workflow writes install instructions into every new dependency's README.** If the one-liner ever changes, every previously generated README is stale. It should not change; if it must, plan the migration explicitly.
- **The deploy token is currently expired** (`SUEDE_DEPENDENCY_TEMPLATE_PAT`, was 2026-06-30). Anything touching the downstream template push is blocked until it is rotated — worth resolving before M7.
- **Don't let the planner leak I/O.** The moment `plan()` calls git, the §5.1 matrix stops being cheap and starts being fixtures. Enforce it with a review rule, or a test that monkeypatches the git module to raise on any call during planning.
