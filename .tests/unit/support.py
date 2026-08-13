"""Builders that let a scenario be written as a literal tree.

The planner and `check` are pure over `World`, so everything they decide can be
asserted without a git repository, a filesystem or a network. Keeping the
builders here is what makes each test read as its scenario rather than as
setup.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "scripts"))

import suede  # noqa: E402

REMOTE_HOST = "https://example.test/acme"


def pin(name, commit, remote=None, branch="release"):
    return suede.Pin(
        remote=remote or "%s/%s" % (REMOTE_HOST, name),
        commit=(commit * 40)[:40],
        branch=branch,
    )


def manifest(edges=None, npm=None, python=None, python_extras=()):
    return suede.Manifest(
        edges=dict(edges or {}),
        npm=dict(npm or {}),
        python=dict(python or {}),
        python_extras=tuple(python_extras),
    )


def world(
    repo="app",
    sep=".",
    installs=None,
    links=None,
    files=None,
    edges=None,
    records=None,
    npm=None,
    npm_dev=None,
    python=None,
    python_dev=None,
    has_release=True,
    head="0" * 40,
    dirty=False,
    vendored=(),
):
    """`installs` maps a real directory to its pin; `links` maps an entry path
    to the directory it resolves to; `edges` lists (dependent path, entry name,
    pin) triples as a dependency's manifest would. `vendored` is the same shape
    as `installs`, for the subrepos that live inside release/ - a bare sequence
    of paths works too, where only the classification is under test."""
    installs = dict(installs or {})
    vendored = _vendored(vendored)
    entries = _entries(installs, vendored, dict(links or {}), list(files or []))
    return suede.World(
        root="/nowhere",
        repo=repo,
        sep=sep,
        sep_source="flag",
        head=head,
        dirty=dirty,
        has_release=has_release,
        installs={path: suede.Install(path=path, pin=held) for path, held in installs.items()},
        entries=entries,
        edges=tuple(suede.Edge(*edge) for edge in (edges or [])),
        vendored=vendored,
        npm=dict(npm or {}),
        npm_dev=dict(npm_dev or {}),
        python=dict(python or {}),
        python_dev=dict(python_dev or {}),
        records=dict(records or {}),
    )


def _vendored(given):
    if not isinstance(given, dict):
        given = {path: pin(os.path.basename(path), "v") for path in given}
    return {path: suede.Install(path=path, pin=held) for path, held in given.items()}


def _entries(installs, vendored, links, files):
    entries = {}
    for path in list(installs) + list(vendored):
        entries[path] = _entry(path, "folder", target=path)
    for path, target in links.items():
        entries[path] = _entry(path, "symlink" if target else "dangling", target=target or None)
    for path in files:
        entries[path] = _entry(path, "file")
    return entries


def _entry(path, kind, target=None):
    return suede.Entry(path=path, name=os.path.basename(path), kind=kind, target=target)


def request(*pins, **overrides):
    return suede.Request(pins=tuple(pins), **overrides)


def ancestry(*older_then_newer):
    """(older, newer) pairs, as `git merge-base --is-ancestor` would answer."""
    table = {}
    for older, newer in older_then_newer:
        table[(older.commit, newer.commit)] = True
        table[(newer.commit, older.commit)] = False
    return table


def ops(plan, op):
    return [act for act in plan.acts if act.op == op]


def entries_of(plan, op):
    return [act.entry for act in ops(plan, op)]
