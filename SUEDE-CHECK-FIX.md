# `suede check`: a dev dependency with dependencies can never pass

**Where this belongs:** `pmalacho-mit/suede`, the `dependency/main/core` branch — the source of
`suede.py`. Not the copy vendored at `.suede/core` in this repo, which is behind and on its way out.

**Symptom:** [CI run 31668338197](https://github.com/pmalacho-mit/dockview-svelte-suede/actions/runs/31668338197/job/94347674870)
on `dockview-svelte-suede`:

```
FAIL  sweater-vest-suede.programmatic-docker-suede   sweater-vest-suede.programmatic-docker-suede
      resolves to sweater-vest-suede.programmatic-docker-suede, which no root entry declares as a
      release dependency. That is an implicit dependency: give it a root entry so it ships in your
      manifest.
```

…and four more like it. Every one of them descends from `sweater-vest-suede`, which is a
**development** dependency: it is imported by `src/tests/`, never by `release/`.

---

## 1. It is not the prefix rule

The first guess was that `declarations.is_prefixed` matches `${string}${SEP}${name}` where it
should match `${root-repo}${SEP}${name}`. It already does the latter:

```python
def is_prefixed(world: World, name: str) -> bool:
    return any(
        name.startswith(world.repo + separator)
        and len(name) > len(world.repo + separator)
        for separator in declarations._separators(world)
    )
```

Probing the real `World` for `dockview-svelte-suede`:

```
repo='dockview-svelte-suede' sep='.' (file)

root entries -> is_prefixed (i.e. declares a release dependency)?
  sweater-vest-suede                                          False
  sweater-vest-suede.browser-control-container-suede          False
  sweater-vest-suede.dockview-svelte-suede                    False
  sweater-vest-suede.programmatic-docker-suede                False
  sweater-vest-suede.typescript-cli-suede                     False
  browser-control-container-suede.programmatic-docker-suede   False

declared release deps: {}
classify: every install -> "development"
```

Nothing is being over-matched, and nothing is being wrongly promoted. Those `x.y` entries are
**edge aliases**, not declarations: names that a *dependent's* manifest demands of its siblings, so
that `../sweater-vest-suede.programmatic-docker-suede` resolves from inside `sweater-vest-suede/`.
The prefix that makes an entry a declaration is the *root repo's*, and none of them carry it —
correctly, because this repo has no release dependencies at all. `classify()` says so itself.

## 2. It is the edge check ignoring that classification

```python
def _edge_findings(world: World) -> Iterable[Finding]:
    declared = declarations.backing_paths(world)
    for edge in world.edges:                      # <- every edge of every install
        ...
        elif backing not in declared:
            yield _undeclared_edge(edge, path, backing)
```

`world.edges` is built by `_read_edges` from the manifest of **every** install, whether or not that
install ships. The declaration invariant is then applied to all of them, so an edge belonging to a
development dependency is judged by a rule about the release manifest.

Two things follow, and both are visible in the failure above:

- **A dev dependency that has dependencies of its own can never pass `check`.** One with no
  dependencies is fine, which is why the direct entry `sweater-vest-suede` produces no finding and
  its four transitive deps produce four.
- **The remedy the message proposes is wrong here.** "Give it a root entry so it ships in your
  manifest" means adding `dockview-svelte-suede.programmatic-docker-suede` and friends — declaring
  a containerised browser driver, a docker wrapper and a CLI helper as release dependencies of a
  Svelte docking library that imports none of them. The invariant exists to keep the shipped
  manifest honest; applying it to code that never ships inverts it.

`classify()` already models the distinction (`"release"` vs `"development"`, used by `list`).
`check()` simply never asks.

## 3. The fix

Consult a release graph — the declared release dependencies, everything they reach transitively,
and whatever `release/` vendors — and apply the declaration invariant only to edges whose dependent
is in it. `missing-edge` keeps applying to everything: a dangling sibling breaks dev tooling just as
surely as it breaks a shipped one.

```diff
 def _edge_findings(world: World) -> Iterable[Finding]:
     declared = declarations.backing_paths(world)
+    shipped = _release_graph(world)
     for edge in world.edges:
         path = _sibling_path(edge)
         entry = world.entries.get(path)
         backing = entry.backing if entry else None
         if backing is None:
             yield _missing_edge(edge, path, entry)
-        elif backing not in declared:
-            yield _undeclared_edge(edge, path, backing)
-        else:
+        elif backing in declared:
             for finding in _pin_notes(world, edge, path, backing):
                 yield finding
+        elif edge.dependent in shipped:
+            yield _undeclared_edge(edge, path, backing)
+
+
+def _release_graph(world: World) -> FrozenSet[str]:
+    """Installs whose own dependencies ship: the declared release dependencies,
+    everything they reach, and whatever `release/` vendors. A development
+    dependency ships nothing, so what it depends on is its own business -
+    demanding a root entry for those would put dev-only tooling in the manifest."""
+    reached: Set[str] = set()
+    frontier = set(declarations.backing_paths(world)) | set(world.vendored)
+    while frontier:
+        path = frontier.pop()
+        if path in reached:
+            continue
+        reached.add(path)
+        frontier.update(_resolved_backings(world, path))
+    return frozenset(reached)
+
+
+def _resolved_backings(world: World, dependent: str) -> Iterable[str]:
+    for edge in world.edges:
+        if edge.dependent != dependent:
+            continue
+        entry = world.entries.get(_sibling_path(edge))
+        if entry and entry.backing:
+            yield entry.backing
```

Plus `FrozenSet` and `Set` on the `typing` import.

Notes on the shape:

- **`world.vendored` seeds the frontier** alongside the declared installs. A subrepo vendored under
  `release/` ships as source, so its edges are held to the invariant exactly like a declared one.
- **The closure matters.** A release dependency's dependency is itself part of the shipped graph, so
  an implicit dependency two hops in must still fail. A depth-1 check would miss it.
- **The `declared` branch moved above the `shipped` branch** so `_pin_notes` still runs for every
  declared resolution, unchanged.

## 4. Verification

Six synthetic worlds, chosen so the fix cannot pass by simply staying quiet:

| Case | Before | After |
| --- | --- | --- |
| Release dep → undeclared sibling | FAIL | **FAIL** |
| Release dep → declared sibling | INFO (pin notes) | INFO (pin notes) |
| Release dep → declared → undeclared (two hops) | FAIL | **FAIL** |
| Vendored-under-`release/` dep → undeclared sibling | FAIL | **FAIL** |
| Same tree, not vendored (dev-only) | FAIL | clean |
| Dev dep → its own dependency *(the reported failure)* | FAIL | clean |
| Dev dep → missing sibling | FAIL (`missing-edge`) | **FAIL** (`missing-edge`) |

On the real repo, `python3 suede.py check` goes from five FAILs to `check: no problems found`, and
`list` is unchanged.

The harness, worth keeping as a test — it builds `World` objects directly, so it needs no fixture
tree on disk:

```python
import os
import suede as s

def pin(name):
    return s.Pin(remote="https://github.com/o/%s.git" % name, commit="0" * 40)

def folder(path):
    return s.Entry(path=path, name=os.path.basename(path), kind="folder", target=path)

def world(entries, installs, edges, vendored=()):
    return s.World(
        root="/tmp/x", repo="root-repo", sep=".", sep_source="file", head="0" * 40,
        installs={p: s.Install(path=p, pin=pin(os.path.basename(p))) for p in installs},
        entries={e.path: e for e in entries},
        edges=tuple(edges),
        vendored=vendored,
    )

# the reported failure: a development dependency with a dependency of its own
dev = world(
    entries=[folder("devtool"), folder("devtool.helper")],
    installs=["devtool", "devtool.helper"],
    edges=[s.Edge(dependent="devtool", entry_name="devtool.helper", pin=pin("helper"))],
)
assert s.check(dev) == ()

# a release dependency with an implicit dependency, two hops in, must still fail
deep = world(
    entries=[folder("root-repo.lib"),
             s.Entry(path="lib.mid", name="lib.mid", kind="symlink", target="root-repo.mid"),
             folder("root-repo.mid"), folder("mid.deep")],
    installs=["root-repo.lib", "root-repo.mid", "mid.deep"],
    edges=[s.Edge(dependent="root-repo.lib", entry_name="lib.mid", pin=pin("mid")),
           s.Edge(dependent="root-repo.mid", entry_name="mid.deep", pin=pin("deep"))],
)
assert any(f.code == "undeclared-edge" for f in s.check(deep))
```

## 5. Two things noticed alongside

- **`.worktrees/` is scanned.** A git worktree living inside the repo is walked like any other
  directory, so every install and every finding is reported twice — locally this turned five FAILs
  into ten, and `list` shows each dependency twice. CI checks out clean, so it never sees this.
  Worth skipping the way `MACHINERY` is skipped.
- **"development" is inferred, never declared.** An install is development precisely because
  *nothing* points at it, which means a typo'd or half-finished release entry looks identical to a
  deliberate dev dependency. `_entry_findings` catches one shape of that (`dangling-entry`, when a
  correctly-prefixed name has no backing), but there is no signal for the reverse — a dependency
  that was meant to ship and never got its root entry. If dev dependencies became declarable rather
  than inferred, `check` could tell those apart, and the fix above would read as
  "development dependencies are exempt" rather than "unreachable installs are exempt".
