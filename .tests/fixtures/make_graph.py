"""Build a dependency graph of local bare repos from a small spec.

    GRAPH = {
      "dockview": {},
      "sweater":  {"sweater.dockview": ("dockview", "HEAD")},
      "renderer": {"renderer.dockview": ("dockview", "HEAD~3")},   # conflict
    }

Each node becomes a bare repo with a `release` branch and a real
`.suede/.dependencies/`, so a fixture exercises the actual manifest format
rather than a mock of it. Nodes are built in dependency order; a spec with a
cycle is rejected rather than half-built.
"""

import os
import subprocess

COMMITS_PER_NODE = 5

GIT_IDENTITY = {
    "GIT_AUTHOR_NAME": "suede tests",
    "GIT_AUTHOR_EMAIL": "tests@example.test",
    "GIT_COMMITTER_NAME": "suede tests",
    "GIT_COMMITTER_EMAIL": "tests@example.test",
}


class Node:
    def __init__(self, name, remote, commits):
        self.name = name
        self.remote = remote
        self.commits = commits  # oldest first

    def at(self, revision):
        """`HEAD`, or `HEAD~<n>` counting back from the release tip."""
        if revision in ("HEAD", "", None):
            return self.commits[-1]
        return self.commits[-1 - int(revision.split("~")[1])]


def build(graph, directory, publishes=None):
    """`publishes` maps a node to extra files for its `.suede/.dependencies/`
    - `package.json`, `requirements.txt` - as text, so a fixture publishes what
    a real dependency publishes rather than a mock of it."""
    published = publishes or {}
    nodes = {}
    for name in _dependency_order(graph):
        nodes[name] = _build_node(
            name, graph[name], nodes, directory, published.get(name, {})
        )
    return nodes


def _dependency_order(graph):
    ordered, remaining = [], dict(graph)
    while remaining:
        ready = [
            name
            for name, deps in remaining.items()
            if all(target in ordered for target, _ in deps.values())
        ]
        if not ready:
            raise ValueError("dependency cycle in the fixture spec: %s" % sorted(remaining))
        ordered += sorted(ready)
        for name in ready:
            del remaining[name]
    return ordered


def _build_node(name, dependencies, built, directory, published):
    remote = os.path.join(directory, name + ".git")
    work = os.path.join(directory, "work", name)
    git("init", "--quiet", "--bare", "--initial-branch=release", remote)
    git("init", "--quiet", "--initial-branch=release", work)
    commits = [_commit_content(work, name, index) for index in range(COMMITS_PER_NODE)]
    if dependencies or published:
        _write_manifest(work, dependencies, built)
        for filename, content in sorted(published.items()):
            write(os.path.join(work, ".suede", ".dependencies", filename), content)
        commits.append(_commit(work, "declare dependencies"))
    git("push", "--quiet", remote, "release", cwd=work)
    return Node(name=name, remote=remote, commits=commits)


def _commit_content(work, name, index):
    write(os.path.join(work, "index.ts"), 'export const %s = %d;\n' % (name.replace("-", "_"), index))
    return _commit(work, "%s v%d" % (name, index))


def _write_manifest(work, dependencies, built):
    for entry_name, (target, revision) in sorted(dependencies.items()):
        node = built[target]
        write(
            os.path.join(work, ".suede", ".dependencies", entry_name + ".gitrepo"),
            "[subrepo]\n\tremote = %s\n\tbranch = release\n\tcommit = %s\n"
            % (node.remote, node.at(revision)),
        )


def _commit(work, message):
    git("add", "-A", cwd=work)
    git("commit", "--quiet", "-m", message, cwd=work)
    return git("rev-parse", "HEAD", cwd=work)


def write(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(content)


def git(*args, **kwargs):
    environment = dict(os.environ, **GIT_IDENTITY)
    result = subprocess.run(
        ("git",) + args,
        cwd=kwargs.get("cwd"),
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True,
    )
    if result.returncode != 0:
        raise RuntimeError("git %s failed:\n%s" % (" ".join(args), result.stderr))
    return result.stdout.strip()


def consumer(directory, name="app", release=False):
    """A repository that installs things: one commit, so HEAD resolves."""
    path = os.path.join(directory, name)
    git("init", "--quiet", "--initial-branch=main", path)
    git("config", "user.name", GIT_IDENTITY["GIT_AUTHOR_NAME"], cwd=path)
    git("config", "user.email", GIT_IDENTITY["GIT_AUTHOR_EMAIL"], cwd=path)
    write(os.path.join(path, "src", "main.ts"), "export const main = 1;\n")
    if release:
        write(os.path.join(path, "release", "index.ts"), "export * from './main';\n")
    _commit(path, "initial")
    return path
