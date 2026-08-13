#!/usr/bin/env python3
"""suede - install, audit and publish suede dependencies.

One dependency-free file, so a consumer who hits a problem on an unusual system
can read it, patch it, and move on.

Sections run in a strict dependency direction: later sections use earlier ones,
never the reverse. Sections 9-11, 14 and 15's classification are pure functions
over the model; every call to git is confined to section 4.
"""

from __future__ import annotations

import sys

MINIMUM_PYTHON = (3, 9)


def refuse_old_python() -> None:
    if sys.version_info >= MINIMUM_PYTHON:
        return
    _ = sys.stderr.write( 
        "suede needs Python %d.%d or newer (this is %s).\n"
        "  macOS ships 3.9.6 with the Command Line Tools, which is enough.\n"
        "  Install a newer python3 and re-run.\n"
        % (MINIMUM_PYTHON[0], MINIMUM_PYTHON[1], ".".join(str(n) for n in sys.version_info[:3]))
    )
    raise SystemExit(3)


refuse_old_python()

import argparse  # noqa: E402
import hashlib  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402
import shutil  # noqa: E402
import subprocess  # noqa: E402
import tempfile  # noqa: E402
import time  # noqa: E402
from collections import Counter, deque  # noqa: E402
from collections.abc import Callable, Iterable, Mapping, Sequence  # noqa: E402
from dataclasses import dataclass, field, replace  # noqa: E402
from typing import Final, Optional, TextIO, TypeVar, cast  # noqa: E402

_T = TypeVar("_T")

# --------------------------------------------------------------------------- #
# 1. Constants                                                                 #
# --------------------------------------------------------------------------- #

RELEASE_DIR = "release"
MANIFEST_DIR = os.path.join(".suede", ".dependencies")
# Where `--vendor` puts the bytes: the top of release/, beside the code that
# imports them, which is also what `vendor.sh --dest` defaults to. Not a
# subdirectory of `.suede/` - a leading dot is unrepresentable in a Python
# import, so anything nested there is reachable from `release/` code in some
# languages and not in others.
VENDOR_DIR = RELEASE_DIR
# Where pre-2.0 dependencies published their manifest. Read so a plan is right
# even when a dependency has not republished yet, and reported so it does.
LEGACY_MANIFEST_DIR = ".dependencies"
SEPARATOR_FILE = os.path.join(MANIFEST_DIR, "separator")
GITREPO = ".gitrepo"
RELEASE_BRANCH = "release"
SHORT_SHA = 7

# The three kinds of dependency, which are three answers to one question: where
# do the bytes land, and does the release branch know about them. Everything
# else - naming, what may satisfy an edge, what gets recorded - follows from
# that. See DEPENDENCIES-OF-DEPENDENCIES.md.
RELEASE_KIND = "release"
DEVELOPMENT_KIND = "development"
VENDORED_KIND = "vendored"

PACKAGE_JSON = "package.json"
REQUIREMENTS = "requirements.txt"
# A development dependency's packages must not reach the consumers of *this*
# project, and `extract` publishes `dependencies` and requirements.txt verbatim.
# These two are the dev half of each ecosystem, and neither is published.
NPM_SECTION = "dependencies"
NPM_DEV_SECTION = "devDependencies"
DEV_REQUIREMENTS = "requirements-dev.txt"

# `.` and `__` are always legal, whatever a project declares for itself: a
# dependency's entries are named by its authors, not by us.
LEGAL_SEPARATORS = (".", "__")
DEFAULT_SEPARATOR = "."

# The separator must be legal inside a module identifier in the importing
# language. `.` works wherever an import is a path literal; `__` is required
# wherever a path segment surfaces as an identifier.
SEPARATOR_BY_EXTENSION = {
    "c": ".",
    "cjs": ".",
    "cpp": ".",
    "css": ".",
    "go": ".",
    "h": ".",
    "hpp": ".",
    "js": ".",
    "jsx": ".",
    "mjs": ".",
    "py": "__",
    "pyi": "__",
    "rb": "__",
    "rs": "__",
    "scss": ".",
    "sh": ".",
    "svelte": ".",
    "ts": ".",
    "tsx": ".",
    "vue": ".",
}

# How suede's own git calls are allowed to fail: fast, and without asking
# anyone anything.
#
# A network that DROPS port 22 rather than refusing it - which is most proxied
# and corporate networks - turns an SSH attempt into a full TCP timeout. Left
# unbounded that is over two minutes per remote, paid before the HTTPS spelling
# is ever tried. BatchMode turns a missing key or an unknown host into an
# immediate failure instead of a prompt nobody is there to answer.
#
# Neither setting reaches the user's own `git subrepo pull`: that is a separate
# process with its own configuration. Both defer to a value already in the
# environment.
SSH_ATTEMPT = "ssh -o BatchMode=yes -o ConnectTimeout=5"

CACHE_DIR = os.path.join(".git", "suede-cache")
CACHE_MAX_AGE_SECONDS = 30 * 24 * 60 * 60

NEVER_WALK = (".git", "node_modules")

# Prompts go here, never to stdin: the bootstrap pipes a .gitrepo into stdin.
TERMINAL = "/dev/tty"
# A person mistypes a few times; a prompt that has read nothing usable this
# many times is not talking to a person, and should say so rather than spin.
MAX_PROMPTS = 10

# suede's own vendored machinery. These are subrepos, so they look exactly like
# dependencies, but they are how a dependency gets its workflows and core
# scripts - not something it depends on. Classifying them would put suede's
# plumbing in every `list` and announce it as vendored code on every install.
MACHINERY = (os.path.join(".suede", "core"), os.path.join(".github", "workflows"))

SUBREPO_METHOD = "merge"
SUBREPO_CMDVER = "0.4.9"

GITREPO_HEADER = (
    "; DO NOT EDIT (unless you know what you are doing)\n"
    ";\n"
    '; This subdirectory is a git "subrepo", and this file is maintained automatically\n'
    "; by the git-subrepo command. See https://github.com/ingydotnet/git-subrepo#readme\n"
    ";\n"
)

OP_ORDER = ("install", "reuse", "link", "copy", "record", "override", "npm", "pip")
MUTATING_OPS = ("install", "link", "copy", "record", "npm", "pip")

# What a blocker tells you to do when a dependency's package declarations
# disagree with your own. Naming the flag is the whole point: the alternative
# is a refusal with no way past it.
ALLOW_CONFLICTS_FLAG = "--allow-conflicting-packages"


class Exit:
    OK: Final = 0
    ERROR: Final = 1
    USAGE: Final = 2
    PRECONDITION: Final = 3
    UNRESOLVED: Final = 4
    CHECK_FAILED: Final = 5


# --------------------------------------------------------------------------- #
# 2. Errors                                                                    #
# --------------------------------------------------------------------------- #


class SuedeError(Exception):
    code: int = Exit.ERROR


class Usage(SuedeError):
    code: int = Exit.USAGE


class Precondition(SuedeError):
    code: int = Exit.PRECONDITION


class PlanError(SuedeError):
    code: int = Exit.UNRESOLVED


# --------------------------------------------------------------------------- #
# 3. Model                                                                     #
# --------------------------------------------------------------------------- #


class remotes:
    """One repository, three spellings of its URL.

    A developer pushes over SSH, because that is the only route left for
    authenticating a write. A consumer - and every CI runner - reads over
    HTTPS, because that needs no key. Both are the same dependency, so the
    model compares neither: it compares `canonical`, and derives the other two
    at the moment it writes a file or talks to a remote.

    Anything that is not a host-and-path pair - a local directory, a `file://`
    URL, an address carrying a port - has one spelling, which is itself.
    """

    @staticmethod
    def canonical(url: str) -> str:
        """The identity. Two spellings of one repository share it; nothing else
        does."""
        pair = remotes._host_and_path(url)
        return url if pair is None else "https://%s/%s" % pair

    @staticmethod
    def ssh(url: str) -> str:
        pair = remotes._host_and_path(url)
        return url if pair is None else "git@%s:%s.git" % pair

    @staticmethod
    def https(url: str) -> str:
        return remotes.canonical(url)

    @staticmethod
    def candidates(url: str) -> tuple[str, ...]:
        """What to try, in order. SSH first: a key in the environment is the
        only route to a private repository. HTTPS second: it is the only route
        without one."""
        pair = remotes._host_and_path(url)
        if pair is None:
            return (url,)
        return (remotes.ssh(url), remotes.https(url))

    @staticmethod
    def name(url: str) -> str:
        """The dependency's identity: the remote's basename, `.git` stripped."""
        return url.rstrip("/").rsplit("/", 1)[-1].rsplit(":", 1)[-1].removesuffix(".git")

    @staticmethod
    def _host_and_path(url: str) -> Optional[tuple[str, str]]:
        pair = remotes._scheme_form(url) if "://" in url else remotes._scp_form(url)
        if pair is None:
            return None
        host, path = pair
        # A port means the two spellings cannot be derived from each other, and
        # a host without a dot is a local path (`C:\repo`) or an alias, not an
        # address we can rewrite. Refuse rather than invent a URL.
        if ":" in host or "." not in host or not path:
            return None
        return host, path.rstrip("/").removesuffix(".git")

    @staticmethod
    def _scheme_form(url: str) -> Optional[tuple[str, str]]:
        """`https://host/path`, `ssh://git@host/path`."""
        for scheme in ("https://", "http://", "ssh://", "git://"):
            if url.startswith(scheme):
                authority, _, path = url[len(scheme) :].partition("/")
                return authority.rsplit("@", 1)[-1], path
        return None

    @staticmethod
    def _scp_form(url: str) -> Optional[tuple[str, str]]:
        """`git@host:path`. The colon must precede any slash, or this is a
        local path that happens to contain one."""
        host, separator, path = url.partition(":")
        if not separator or "/" in host:
            return None
        return host.rsplit("@", 1)[-1], path


@dataclass(frozen=True, order=True)
class Pin:
    remote: str
    commit: str
    branch: str = RELEASE_BRANCH

    def __post_init__(self) -> None:
        """Codified rather than documented: a Pin cannot hold a spelling the
        rest of the model would fail to recognise as the same repository."""
        object.__setattr__(self, "remote", remotes.canonical(self.remote))

    @property
    def short(self) -> str:
        return self.commit[:SHORT_SHA]

    @property
    def name(self) -> str:
        return remotes.name(self.remote)


@dataclass(frozen=True)
class Entry:
    path: str  # repo-relative path of the entry itself
    name: str  # basename, verbatim
    kind: str  # "folder" | "symlink" | "dangling" | "file"
    target: Optional[str] = None  # repo-relative realpath when it resolves to a directory

    @property
    def backing(self) -> Optional[str]:
        """The directory this entry stands for, or None if it doesn't name one."""
        if self.kind == "folder":
            return self.path
        return self.target


@dataclass(frozen=True)
class Install:
    path: str  # repo-relative real directory
    pin: Pin
    parent: str = ""  # the .gitrepo `parent` field


@dataclass(frozen=True)
class Edge:
    dependent: str  # install path of the dependent
    entry_name: str  # manifest filename, verbatim
    pin: Pin  # what the dependent asked for


@dataclass(frozen=True)
class Manifest:
    edges: Mapping[str, Pin] = field(default_factory=dict[str, Pin])
    npm: Mapping[str, str] = field(default_factory=dict[str, str])
    python: Mapping[str, str] = field(default_factory=dict[str, str])
    python_extras: tuple[str, ...] = ()  # requirements.txt lines that name no package
    legacy: bool = False  # published at the pre-2.0 path


EMPTY_MANIFEST = Manifest()


@dataclass(frozen=True)
class World:
    root: str
    repo: str
    sep: str
    sep_source: str  # "flag"|"file"|"entries"|"inferred"|"default"
    head: Optional[str]  # None => unborn HEAD
    dirty: bool = False
    has_release: bool = False
    installs: Mapping[str, Install] = field(default_factory=dict[str, Install])  # path -> Install
    entries: Mapping[str, Entry] = field(default_factory=dict[str, Entry])  # path -> Entry
    edges: tuple[Edge, ...] = ()
    # Subrepos inside release/. They ship as source rather than as a pointer,
    # so they are held apart from `installs` - one can never satisfy a release
    # dependency's edge - but they are installs on disk, and a `--vendor` run
    # has to see their pins to avoid vendoring the same commit twice.
    vendored: Mapping[str, Install] = field(default_factory=dict[str, Install])  # path -> Install
    npm: Mapping[str, str] = field(default_factory=dict[str, str])
    npm_dev: Mapping[str, str] = field(default_factory=dict[str, str])
    python: Mapping[str, str] = field(default_factory=dict[str, str])
    python_dev: Mapping[str, str] = field(default_factory=dict[str, str])
    records: Mapping[str, Pin] = field(default_factory=dict[str, Pin])  # what release/ already ships


@dataclass(frozen=True)
class Act:
    op: str  # see OP_ORDER
    entry: str
    pin: Optional[Pin] = None
    dest: Optional[str] = None
    target: Optional[str] = None
    reason: str = ""
    section: str = ""  # for an npm act: which package.json block it merges into

    # Which of the optional fields an act carries is decided by its op, and
    # every applier runs on one op only. These name what its op promises, so a
    # planner bug says so here instead of reaching shutil as a None.
    @property
    def required_pin(self) -> Pin:
        if self.pin is None:
            raise self._missing("pin")
        return self.pin

    @property
    def required_dest(self) -> str:
        if self.dest is None:
            raise self._missing("dest")
        return self.dest

    @property
    def required_target(self) -> str:
        if self.target is None:
            raise self._missing("target")
        return self.target

    def _missing(self, field_name: str) -> PlanError:
        return PlanError("%s act for %s carries no %s" % (self.op, self.entry, field_name))


@dataclass(frozen=True)
class Claim:
    dependent: Optional[str]  # dependency name of the claimant; None => the root project
    pin: Pin


@dataclass(frozen=True)
class Option:
    """A resolution offered for a conflict, stated as its filesystem outcome:
    what gets installed, and which demanded pin each install then satisfies."""

    id: str  # "coexist" | "unify" | "defer"
    label: str
    risk: str
    placements: tuple[tuple[Pin, str], ...] = ()  # pin -> entry name to install
    assignments: tuple[tuple[Pin, str], ...] = ()  # demanded pin -> entry satisfying it
    pin: Optional[Pin] = None  # the commit a `unify` option settles on
    backed_by: Optional[Pin] = None  # what an already-installed entry holds

    @property
    def entries(self) -> tuple[str, ...]:
        return tuple(entry for _, entry in self.placements)


@dataclass(frozen=True)
class Conflict:
    remote: str
    claims: tuple[Claim, ...]
    ancestry: str  # "ancestor"|"descendant"|"diverged"|"unknown"
    options: tuple[Option, ...]
    involves_root: bool = False
    kind: str = "commit"  # "commit" | "ambiguous"


@dataclass(frozen=True)
class Plan:
    acts: tuple[Act, ...] = ()
    conflicts: tuple[Conflict, ...] = ()
    warnings: tuple[str, ...] = ()
    blockers: tuple[str, ...] = ()  # non-empty => refuse to apply

    @property
    def mutates(self) -> bool:
        return any(act.op in MUTATING_OPS for act in self.acts)


@dataclass(frozen=True)
class Request:
    pins: tuple[Pin, ...] = ()
    kind: str = RELEASE_KIND  # release | development | vendored
    name: Optional[str] = None  # --name, applies to a single requested pin
    target: str = ""  # --target, repo-relative; "" => flat at the repo root
    link_mode: str = "symlink"  # symlink | copy
    commit_suffix: bool = False  # pin the entry name to the commit as well
    # Keep the release arrangement - one install per pin under the dependency's
    # own name, every edge a link - for a kind that would not otherwise use it.
    root_owned: bool = False

    @property
    def edge_named(self) -> bool:
        """Whether a transitive install takes the name its dependent asks for,
        so the entry and the bytes are one thing rather than a folder plus a
        link.

        The ownership rule it replaces exists so the name shipped in a manifest
        is backed by real bytes instead of an indirection into a folder named
        after some other project. Neither a development nor a vendored install
        ships such a name, so for them the rule buys nothing and costs an entry
        per edge - hence the default. A release install has no choice: its
        `$repo$SEP<name>` name *is* the declaration.
        """
        return self.kind != RELEASE_KIND and not self.root_owned


@dataclass(frozen=True)
class Policy:
    on_conflict: str = "defer"  # ask | coexist | unify-newest | defer
    npm: bool = True
    python: bool = True
    # A dependency declaring a package version you already declare differently
    # stops the install. This says: keep mine, install the rest anyway.
    allow_package_conflicts: bool = False
    choices: Mapping[str, int] = field(default_factory=dict[str, int])  # remote -> option index


@dataclass(frozen=True)
class Naming:
    """What a pin's own entry wants to be called. The override applies only to
    what was asked for by name; everything reached transitively is named by the
    rule.

    The `$repo$SEP` prefix is what *announces* a release dependency, so only a
    release install carries it. A development install prefixed that way would be
    promoted to a release dependency by the classification rule and shipped in
    the manifest; a vendored one has no root entry to announce at all.
    """

    repo: str
    sep: str
    kind: str = RELEASE_KIND
    override: Optional[str] = None
    requested: tuple[Pin, ...] = ()
    commit_suffix: bool = False
    # pin -> the entry name its dependent already asks for. Give the bytes that
    # name and the edge needs no link, because the entry and the install are
    # one thing. Nothing asks for the requested pin by name, so it keeps its
    # own. Empty for a root-owned run - see `Request.edge_named`.
    edge_names: Mapping[Pin, str] = field(default_factory=dict[Pin, str])

    def preferred(self, pin: Pin) -> str:
        if self.override and pin in self.requested:
            return self.override
        if pin not in self.requested and pin in self.edge_names:
            return self.edge_names[pin]
        name = self.repo + self.sep + pin.name if self.kind == RELEASE_KIND else pin.name
        return name + "-" + pin.short if self.commit_suffix and pin in self.requested else name


@dataclass(frozen=True)
class Finding:
    level: str  # "FAIL" | "WARN" | "INFO"
    code: str
    where: str
    message: str


@dataclass(frozen=True)
class Layout:
    """Where real installs live, and where the entries pointing at them go."""

    kind: str = RELEASE_KIND
    target: str = ""
    link_mode: str = "symlink"

    @property
    def home(self) -> str:
        """The directory a fresh install lands in. Vendored code has to ship,
        so it lands inside release/ and `--target` has nothing to say about it."""
        return VENDOR_DIR if self.kind == VENDORED_KIND else self.target

    def install_path(self, entry: str) -> str:
        return os.path.join(self.home, entry) if self.home else entry

    def edge_paths(self, dependent_home: str, entry_name: str) -> tuple[str, ...]:
        """An edge is satisfied by a sibling of its dependent.

        Under `--target` the entry goes in both places: the dependent is
        reached through a root symlink, Node resolves `../` through the
        realpath, a bundler with preserveSymlinks resolves it through the link,
        and the two disagree. Nothing else has that ambiguity - a development
        install is a real folder at the root, and a vendored one is a real
        folder inside release/ that nothing at the root points at, so a second
        entry there would be a stray link into shipped code."""
        if not dependent_home:
            return (entry_name,)
        if self.kind != RELEASE_KIND:
            return (os.path.join(dependent_home, entry_name),)
        return (os.path.join(dependent_home, entry_name), entry_name)

    @property
    def link_mode_op(self) -> str:
        return "copy" if self.link_mode == "copy" else "link"


def relative_link(link_path: str, install_path: str) -> str:
    target = os.path.relpath(install_path, os.path.dirname(link_path) or ".")
    return target if target.startswith(".") else "./" + target


# --------------------------------------------------------------------------- #
# 4. Git - the only place subprocess appears                                   #
# --------------------------------------------------------------------------- #


class git:
    @staticmethod
    def run(*args: str, cwd: Optional[str] = None) -> str:
        proc = subprocess.run(
            ("git",) + args,
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
        )
        if proc.returncode != 0:
            raise SuedeError(
                "git %s failed (%d)\n%s" % (" ".join(args), proc.returncode, proc.stderr.strip())
            )
        return proc.stdout.strip()

    @staticmethod
    def ok(*args: str, cwd: Optional[str] = None) -> bool:
        try:
            git.run(*args, cwd=cwd)
            return True
        except SuedeError:
            return False

    @staticmethod
    def toplevel() -> str:
        try:
            return git.run("rev-parse", "--show-toplevel")
        except SuedeError:
            raise Precondition("not inside a git repository - run suede from a working tree")

    @staticmethod
    def head(cwd: Optional[str] = None) -> Optional[str]:
        try:
            return git.run("rev-parse", "--verify", "HEAD", cwd=cwd)
        except SuedeError:
            return None

    @staticmethod
    def is_dirty(cwd: Optional[str] = None) -> bool:
        return bool(git.run("status", "--porcelain", cwd=cwd))

    @staticmethod
    def tracked_files(cwd: Optional[str] = None) -> list[str]:
        listing = git.run("ls-files", cwd=cwd)
        return listing.splitlines() if listing else []

    @staticmethod
    def remote_url(name: str = "origin", cwd: Optional[str] = None) -> Optional[str]:
        try:
            return git.run("remote", "get-url", name, cwd=cwd)
        except SuedeError:
            return None

    @staticmethod
    def over(url: str, reach: Callable[[str], _T]) -> _T:
        """Run `reach` against each spelling of `url` until one answers.

        SSH is tried first so a key in the environment is enough for a private
        repository; HTTPS is tried second so a runner holding no key still
        works. A remote with only one spelling makes exactly one attempt, which
        is every local path and every address carrying a port.
        """
        attempts = remotes.candidates(url)
        for index, candidate in enumerate(attempts):
            try:
                return reach(candidate)
            except SuedeError as failure:
                if index == len(attempts) - 1:
                    raise git._exhausted(url, attempts, failure)
        raise git._exhausted(url, attempts, SuedeError("no spelling to try"))

    @staticmethod
    def _exhausted(url: str, attempts: Sequence[str], last: SuedeError) -> SuedeError:
        if len(attempts) < 2:
            return last
        return SuedeError(
            "could not reach %s over SSH or HTTPS.\n  tried: %s\n  %s"
            % (url, ", ".join(attempts), last)
        )

    @staticmethod
    def resolve_branch(url: str, branch: str) -> str:
        def ls_remote(candidate: str) -> str:
            listing = git.run("ls-remote", "--exit-code", candidate, "refs/heads/" + branch)
            return listing.split()[0]

        return git.over(url, ls_remote)

    @staticmethod
    def fetch_commit(url: str, commit: str, branch: str, dest: str) -> None:
        """Materialise one commit's tree at `dest`, history and all discarded."""

        def fetch_from(candidate: str) -> None:
            # Each attempt starts from nothing: a half-fetched directory left by
            # the previous spelling would make this one fail for the wrong
            # reason, and report the wrong fix.
            shutil.rmtree(dest, ignore_errors=True)
            os.makedirs(dest, exist_ok=True)
            git.run("init", "--quiet", cwd=dest)
            git.run("remote", "add", "origin", candidate, cwd=dest)
            if not git.ok("fetch", "--quiet", "--depth", "1", "origin", commit, cwd=dest):
                git.run("fetch", "--quiet", "origin", "refs/heads/" + branch, cwd=dest)
            git.run("checkout", "--quiet", "--detach", commit, cwd=dest)

        git.over(url, fetch_from)

    @staticmethod
    def fetch_history(url: str, branch: str, dest: str) -> None:
        """A blobless mirror - enough history to answer `is_ancestor`, no trees."""

        def clone_from(candidate: str) -> None:
            shutil.rmtree(dest, ignore_errors=True)
            git.run(
                "clone", "--quiet", "--bare", "--filter=blob:none",
                "--branch", branch, candidate, dest,
            )

        git.over(url, clone_from)

    @staticmethod
    def is_ancestor(older: str, newer: str, cwd: str) -> bool:
        return git.ok("merge-base", "--is-ancestor", older, newer, cwd=cwd)

    @staticmethod
    def config_get(path: str, key: str) -> Optional[str]:
        try:
            return git.run("config", "-f", path, "--get", key)
        except SuedeError:
            return None

    @staticmethod
    def config_set(path: str, key: str, value: str) -> None:
        git.run("config", "-f", path, key, value)

    @staticmethod
    def add(paths: Sequence[str], cwd: str) -> None:
        if paths:
            git.run("add", "--", *paths, cwd=cwd)

    @staticmethod
    def commit(message: str, cwd: str) -> str:
        git.run("commit", "--quiet", "-m", message, cwd=cwd)
        return git.run("rev-parse", "--short", "HEAD", cwd=cwd)


# --------------------------------------------------------------------------- #
# 5. .gitrepo files                                                            #
# --------------------------------------------------------------------------- #


class gitrepo:
    """A `.gitrepo` is a git config file; read and write it as one."""

    @staticmethod
    def read(path: str) -> Optional[Pin]:
        remote = git.config_get(path, "subrepo.remote")
        commit = git.config_get(path, "subrepo.commit")
        if not remote or not commit:
            return None
        branch = git.config_get(path, "subrepo.branch") or RELEASE_BRANCH
        return Pin(remote=remote, commit=commit, branch=branch)

    @staticmethod
    def parent(path: str) -> str:
        return git.config_get(path, "subrepo.parent") or ""

    @staticmethod
    def write(path: str, pin: Pin, parent: Optional[str] = None) -> None:
        """A live `.gitrepo` - it drives `git subrepo pull` on the installed
        folder, and a bare `git subrepo push` sends your work back up it. So it
        records the SSH spelling: pushing needs an authenticated write, and
        HTTPS no longer offers one."""
        gitrepo._seed(path)
        gitrepo._set_pin(path, pin, remotes.ssh(pin.remote))
        git.config_set(path, "subrepo.parent", parent or "")
        git.config_set(path, "subrepo.method", SUBREPO_METHOD)
        git.config_set(path, "subrepo.cmdver", SUBREPO_CMDVER)

    @staticmethod
    def write_manifest_record(path: str, pin: Pin) -> None:
        """A shipped pointer, so it records the HTTPS spelling: a consumer
        resolving it has no key of ours, and neither does a CI runner.

        `parent` is a SHA in *our* repository and is meaningless downstream;
        `cmdver` records our local git-subrepo. Neither belongs in something a
        consumer resolves."""
        gitrepo._seed(path)
        gitrepo._set_pin(path, pin, remotes.https(pin.remote))

    @staticmethod
    def _seed(path: str) -> None:
        parent_dir = os.path.dirname(path)
        if parent_dir:
            os.makedirs(parent_dir, exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(GITREPO_HEADER)

    @staticmethod
    def _set_pin(path: str, pin: Pin, remote: str) -> None:
        git.config_set(path, "subrepo.remote", remote)
        git.config_set(path, "subrepo.branch", pin.branch)
        git.config_set(path, "subrepo.commit", pin.commit)

    @staticmethod
    def read_manifest(directory: str) -> Manifest:
        published, legacy = gitrepo._manifest_dir(directory)
        if published is None:
            return EMPTY_MANIFEST
        requirements, extras = pip.declared_in(published)
        return Manifest(
            edges=gitrepo._records_in(published),
            npm=npm.declared_in(published),
            python=requirements,
            python_extras=extras,
            legacy=legacy,
        )

    @staticmethod
    def _manifest_dir(directory: str) -> tuple[Optional[str], bool]:
        current = os.path.join(directory, MANIFEST_DIR)
        if os.path.isdir(current):
            return current, False
        legacy = os.path.join(directory, LEGACY_MANIFEST_DIR)
        if os.path.isdir(legacy):
            return legacy, True
        return None, False

    @staticmethod
    def _records_in(manifest_dir: str) -> dict[str, Pin]:
        records: dict[str, Pin] = {}
        for filename in sorted(os.listdir(manifest_dir)):
            if not filename.endswith(GITREPO):
                continue
            pin = gitrepo.read(os.path.join(manifest_dir, filename))
            if pin:
                records[filename[: -len(GITREPO)]] = pin
        return records


class npm:
    """package.json's `dependencies`, the only part suede has an opinion about."""

    @staticmethod
    def declared_in(directory: str) -> dict[str, str]:
        """A published manifest carries one block: what the dependency needs at
        runtime. Its own dev tooling is its business."""
        return npm.read(os.path.join(directory, PACKAGE_JSON))

    @staticmethod
    def read(path: str, section: str = NPM_SECTION) -> dict[str, str]:
        if not os.path.isfile(path):
            return {}
        try:
            with open(path, encoding="utf-8") as handle:
                document = json.load(handle)
        except (ValueError, OSError):
            return {}
        declared = document.get(section)
        if not isinstance(declared, dict):
            return {}
        # npm writes package -> version range. A package.json that says otherwise
        # is not ours to repair, and copying it out unchanged is the honest read.
        return dict(cast("dict[str, str]", declared))


class pip:
    """`requirements.txt`, read the way `pip install -r` reads it: one
    requirement per line, `#` starts a comment, a trailing backslash continues.

    Keyed by the PEP 503 normalized name, because `Foo_Bar` and `foo-bar` name
    the same distribution and a merge that thinks otherwise declares it twice.
    The value is the line verbatim - extras and environment markers are part of
    the requirement, and re-assembling them from parts is how they get lost.
    """

    @staticmethod
    def declared_in(directory: str) -> tuple[dict[str, str], tuple[str, ...]]:
        return pip.read(os.path.join(directory, "requirements.txt"))

    @staticmethod
    def read(path: str) -> tuple[dict[str, str], tuple[str, ...]]:
        """(requirements, the lines that are not requirements). pip's own
        options - `-r`, `-e`, `--index-url` - name no package, so there is
        nothing to compare them against and nothing to merge them into. They
        are reported rather than dropped in silence."""
        if not os.path.isfile(path):
            return {}, ()
        try:
            with open(path, encoding="utf-8") as handle:
                text = handle.read()
        except OSError:
            return {}, ()
        requirements: dict[str, str] = {}
        others: list[str] = []
        for line in pip._logical_lines(text):
            name = pip._name(line)
            if name is None:
                others.append(line)
            else:
                requirements[name] = line
        return requirements, tuple(others)

    @staticmethod
    def _logical_lines(text: str) -> Iterable[str]:
        for raw in text.replace("\\\n", " ").splitlines():
            line = pip._without_comment(raw).strip()
            if line:
                yield line

    @staticmethod
    def _without_comment(line: str) -> str:
        """A `#` ends the line, except the one in a URL fragment - which is
        never the character after a space."""
        if line.lstrip().startswith("#"):
            return ""
        cut = line.find(" #")
        return line if cut < 0 else line[:cut]

    # What may follow a name: extras, a version specifier, an environment
    # marker, or the `@` of a direct reference.
    NAME_ENDS = "[<>=!~;@(,"

    @staticmethod
    def _name(line: str) -> Optional[str]:
        """The distribution a requirement names, or None where the line opens
        with something else. Anything else is the important half: `git+https://`
        opens with letters, and reading them as a name would have suede merging
        a package called `git`."""
        head = ""
        for char in line:
            if char.isalnum() or char in "-_.":
                head += char
            elif char.isspace() or char in pip.NAME_ENDS:
                break
            else:
                return None
        if not head or not head[0].isalnum():
            return None
        return pip.normalize(head)

    @staticmethod
    def normalize(name: str) -> str:
        """PEP 503: lowercase, and runs of `-`, `_` and `.` collapse to one `-`."""
        collapsed: list[str] = []
        for char in name.lower():
            if char in "-_.":
                if collapsed[-1:] == ["-"]:
                    continue
                collapsed.append("-")
            else:
                collapsed.append(char)
        return "".join(collapsed).strip("-")


# --------------------------------------------------------------------------- #
# 6. Context - $repo and $SEP                                                  #
# --------------------------------------------------------------------------- #


class context:
    @staticmethod
    def repo_name(root: str, override: Optional[str]) -> tuple[str, tuple[str, ...]]:
        """Classification hinges on knowing this verbatim, and forks and local
        renames are exactly where the two automatic sources disagree."""
        if override:
            return override, ()
        from_env = os.environ.get("SUEDE_REPO_NAME")
        if from_env:
            return from_env, ()
        directory = os.path.basename(root)
        from_remote = context._origin_basename(root)
        if not from_remote:
            return directory, ()
        if from_remote != directory:
            return from_remote, (context._name_disagreement(from_remote, directory),)
        return from_remote, ()

    @staticmethod
    def _origin_basename(root: str) -> Optional[str]:
        url = git.remote_url("origin", cwd=root)
        return Pin(remote=url, commit="").name if url else None

    @staticmethod
    def _name_disagreement(from_remote: str, directory: str) -> str:
        return (
            "repo name ambiguous: origin says '%s', the working tree is '%s'. "
            "Using '%s' - pass --repo-name to settle it." % (from_remote, directory, from_remote)
        )

    @staticmethod
    def separator(root: str, repo: str, override: Optional[str]) -> tuple[str, str]:
        for resolve in (
            lambda: (override, "flag"),
            lambda: (context._declared_separator(root), "file"),
            lambda: (context._majority_separator(root, repo), "entries"),
            lambda: (context._inferred_separator(root), "inferred"),
        ):
            separator, source = resolve()
            if separator:
                return separator, source
        return DEFAULT_SEPARATOR, "default"

    @staticmethod
    def _declared_separator(root: str) -> Optional[str]:
        path = os.path.join(root, SEPARATOR_FILE)
        if not os.path.isfile(path):
            return None
        with open(path, encoding="utf-8") as handle:
            return handle.read().strip() or None

    @staticmethod
    def _majority_separator(root: str, repo: str) -> Optional[str]:
        votes: Counter[str] = Counter()
        for name in os.listdir(root):
            for separator in LEGAL_SEPARATORS:
                if name.startswith(repo + separator):
                    votes[separator] += 1
        return context._winner(votes)

    @staticmethod
    def _inferred_separator(root: str) -> Optional[str]:
        """Tracked files only, so .gitignore is respected for free."""
        votes: Counter[str] = Counter()
        for path in git.tracked_files(cwd=root):
            separator = SEPARATOR_BY_EXTENSION.get(path.rsplit(".", 1)[-1].lower())
            if separator:
                votes[separator] += 1
        return context._winner(votes)

    @staticmethod
    def _winner(votes: Counter[str]) -> Optional[str]:
        ranked = votes.most_common()
        if not ranked:
            return None
        if len(ranked) > 1 and ranked[0][1] == ranked[1][1]:
            return None
        return ranked[0][0]

    @staticmethod
    def evidence(root: str, sep: str, source: str) -> str:
        if source != "inferred":
            return ""
        counted = Counter(path.rsplit(".", 1)[-1].lower() for path in git.tracked_files(cwd=root))
        matching = [(ext, n) for ext, n in counted.items() if SEPARATOR_BY_EXTENSION.get(ext) == sep]
        if not matching:
            return ""
        extension, count = max(matching, key=lambda pair: pair[1])
        return "%d of %d tracked files are .%s" % (count, sum(counted.values()), extension)


# --------------------------------------------------------------------------- #
# 7. scan() -> World                                                           #
# --------------------------------------------------------------------------- #


def scan(root: str, repo: str, sep: str, sep_source: str) -> World:
    installs = _find_installs(root)
    vendored = _find_vendored(root)
    return World(
        root=root,
        repo=repo,
        sep=sep,
        sep_source=sep_source,
        head=git.head(cwd=root),
        dirty=git.is_dirty(cwd=root),
        has_release=os.path.isdir(os.path.join(root, RELEASE_DIR)),
        installs=installs,
        entries=_find_entries(root, installs, vendored),
        edges=_read_edges(root, installs, vendored),
        vendored=vendored,
        npm=npm.read(os.path.join(root, PACKAGE_JSON)),
        npm_dev=npm.read(os.path.join(root, PACKAGE_JSON), NPM_DEV_SECTION),
        python=pip.read(os.path.join(root, REQUIREMENTS))[0],
        python_dev=pip.read(os.path.join(root, DEV_REQUIREMENTS))[0],
        records=gitrepo.read_manifest(os.path.join(root, RELEASE_DIR)).edges,
    )


def _find_installs(root: str) -> dict[str, Install]:
    """Every directory holding a `.gitrepo`, outside `release/`. Code inside
    `release/` ships verbatim and so can never satisfy an edge."""
    installs: dict[str, Install] = {}
    for directory in _walk_outside_release(root):
        install = _read_install(root, directory)
        if install:
            installs[install.path] = install
    return installs


def _walk_outside_release(root: str) -> Iterable[str]:
    """Yields candidate directories, never descending into an install: what
    lives inside one is that dependency's business, not ours."""
    for directory, subdirs, _ in os.walk(root):
        subdirs[:] = sorted(d for d in subdirs if d not in NEVER_WALK)
        if directory == root:
            subdirs[:] = [d for d in subdirs if d != RELEASE_DIR]
        elif os.path.isfile(os.path.join(directory, GITREPO)):
            subdirs[:] = []
            yield directory


def _read_install(root: str, directory: str) -> Optional[Install]:
    path = os.path.join(directory, GITREPO)
    pin = gitrepo.read(path)
    if not pin:
        return None
    return Install(path=os.path.relpath(directory, root), pin=pin, parent=gitrepo.parent(path))


def _find_vendored(root: str) -> dict[str, Install]:
    """A subrepo inside `release/` ships with the release branch, source and
    all. Nothing to install - but a nested subrepo should never be a surprise."""
    release = os.path.join(root, RELEASE_DIR)
    if not os.path.isdir(release):
        return {}
    found: dict[str, Install] = {}
    for directory, subdirs, _ in os.walk(release):
        subdirs[:] = sorted(d for d in subdirs if d not in NEVER_WALK)
        # `release/.gitrepo` is the pointer for release/ itself - the folder
        # published to the release branch - not a dependency vendored into it.
        if directory == release:
            continue
        if os.path.isfile(os.path.join(directory, GITREPO)):
            subdirs[:] = []
            install = _read_install(root, directory)
            if install:
                found[install.path] = install
    return found


def _find_entries(
    root: str, installs: Mapping[str, Install], vendored: Mapping[str, Install]
) -> dict[str, Entry]:
    """Root entries, plus the siblings of any install that lives elsewhere -
    an edge is satisfied next to its dependent, wherever that dependent is,
    and a vendored dependent's siblings live inside release/."""
    directories = {"", VENDOR_DIR}
    directories.update(os.path.dirname(path) for path in installs)
    directories.update(os.path.dirname(path) for path in vendored)
    entries: dict[str, Entry] = {}
    for directory in sorted(directories):
        for entry in _entries_in(root, directory):
            entries[entry.path] = entry
    return entries


def _entries_in(root: str, directory: str) -> Iterable[Entry]:
    absolute = os.path.join(root, directory) if directory else root
    if not os.path.isdir(absolute):
        return
    for name in sorted(os.listdir(absolute)):
        if name in NEVER_WALK:
            continue
        yield _describe_entry(root, os.path.join(directory, name) if directory else name)


def _describe_entry(root: str, path: str) -> Entry:
    absolute = os.path.join(root, path)
    name = os.path.basename(path)
    if os.path.islink(absolute):
        return Entry(path=path, name=name, kind=_link_kind(absolute), target=_target(root, absolute))
    if os.path.isdir(absolute):
        return Entry(path=path, name=name, kind="folder", target=path)
    return Entry(path=path, name=name, kind="file")


def _link_kind(absolute: str) -> str:
    return "symlink" if os.path.isdir(absolute) else "dangling"


def _target(root: str, absolute: str) -> Optional[str]:
    if not os.path.isdir(absolute):
        return None
    return os.path.relpath(os.path.realpath(absolute), os.path.realpath(root))


def _read_edges(
    root: str, installs: Mapping[str, Install], vendored: Mapping[str, Install]
) -> tuple[Edge, ...]:
    """A vendored dependency asks for its siblings exactly like any other, and
    ships broken if they are not there - so its manifest is read too."""
    edges: list[Edge] = []
    for path in sorted(set(installs) | set(vendored)):
        manifest = gitrepo.read_manifest(os.path.join(root, path))
        for entry_name in sorted(manifest.edges):
            edges.append(Edge(dependent=path, entry_name=entry_name, pin=manifest.edges[entry_name]))
    return tuple(edges)


# --------------------------------------------------------------------------- #
# 8. Classification - pure over World                                          #
# --------------------------------------------------------------------------- #


class declarations:
    """The classification rule, and the lookups everything downstream needs.

    A release dependency is announced by a root entry named `$repo$SEP<name>`
    whose backing folder sits outside `release/` and holds a `.gitrepo`. The
    separator is part of the match: `suede-extras/` in a repo named `suede`
    must not be silently promoted.
    """

    @staticmethod
    def is_machinery(path: str) -> bool:
        """suede's own vendored plumbing. A subrepo like any other on disk,
        which is why scan reports it - but not something the project depends
        on, so nothing downstream should treat it as one."""
        return any(path == place or path.endswith(os.sep + place) for place in MACHINERY)

    @staticmethod
    def is_prefixed(world: World, name: str) -> bool:
        return any(
            name.startswith(world.repo + separator)
            and len(name) > len(world.repo + separator)
            for separator in declarations._separators(world)
        )

    @staticmethod
    def _separators(world: World) -> tuple[str, ...]:
        if world.sep in LEGAL_SEPARATORS:
            return LEGAL_SEPARATORS
        return LEGAL_SEPARATORS + (world.sep,)

    @staticmethod
    def everything(world: World) -> dict[str, Install]:
        """Every subrepo on disk, wherever it sits. What may be *pointed at*
        depends on the kind of install being planned; what exists does not."""
        return dict(world.installs, **dict(world.vendored))

    @staticmethod
    def entries_in(world: World, directory: str) -> dict[str, Entry]:
        return {
            entry.name: entry
            for path, entry in world.entries.items()
            if os.path.dirname(path) == directory
        }

    @staticmethod
    def root_entries(world: World) -> dict[str, Entry]:
        return {path: entry for path, entry in world.entries.items() if os.path.dirname(path) == ""}

    @staticmethod
    def prefixed_entries(world: World) -> dict[str, Entry]:
        return {
            name: entry
            for name, entry in declarations.root_entries(world).items()
            if declarations.is_prefixed(world, name)
        }

    @staticmethod
    def by_name(world: World) -> dict[str, Install]:
        """Entry name -> the install it declares, for every release dependency."""
        return {
            name: install
            for name, install in declarations.root_installs(world).items()
            if declarations.is_prefixed(world, name)
        }

    @staticmethod
    def root_installs(world: World) -> dict[str, Install]:
        """Every root entry backed by a subrepo, prefix-named or not - so, every
        release dependency plus every development dependency announced at the
        root."""
        backed: dict[str, Install] = {}
        for name, entry in declarations.root_entries(world).items():
            install = declarations.backing_install(world, entry)
            if install and not declarations.is_machinery(install.path):
                backed[name] = install
        return backed

    @staticmethod
    def vendored_entries(world: World) -> dict[str, Install]:
        """Entry name -> the vendored install it names, inside release/."""
        named: dict[str, Install] = {}
        for name, entry in declarations.entries_in(world, VENDOR_DIR).items():
            backing = entry.backing
            install = world.vendored.get(backing) if backing else None
            if install and not declarations.is_machinery(install.path):
                named[name] = install
        return named

    @staticmethod
    def reusable(world: World, kind: str) -> dict[str, Install]:
        """Entry name -> the install it names, for the installs an edge planned
        by a run of this kind may be pointed at.

        The three answers differ because what an edge may resolve to is exactly
        what the classification rule says ships with it. A release dependency's
        edge must land on something declared at the root, or the tree we just
        wrote would fail its own declaration invariant. A development
        dependency ships nothing, so anything already on disk will do - which is
        the point of `--dev`: its dependencies are not doubled as this
        project's. A vendored dependency ships its own bytes, so it may only be
        satisfied from inside release/; a link out of it would ship broken.
        """
        if kind == VENDORED_KIND:
            return declarations.vendored_entries(world)
        if kind == DEVELOPMENT_KIND:
            return declarations.root_installs(world)
        return declarations.by_name(world)

    @staticmethod
    def taken_names(world: World, kind: str) -> tuple[str, ...]:
        """The names a newcomer of this kind must not claim - which is every
        name already used in the directory it would be created in."""
        where = VENDOR_DIR if kind == VENDORED_KIND else ""
        return tuple(declarations.entries_in(world, where))

    @staticmethod
    def backing_install(world: World, entry: Entry) -> Optional[Install]:
        backing = entry.backing
        return world.installs.get(backing) if backing else None

    @staticmethod
    def by_remote(world: World, kind: str = RELEASE_KIND) -> dict[str, dict[Pin, str]]:
        """Remote -> {pin: entry name}. The planner's view of what is already
        resolved, and the reason a coexist install stays addressable."""
        grouped: dict[str, dict[Pin, str]] = {}
        for name, install in sorted(declarations.reusable(world, kind).items()):
            grouped.setdefault(install.pin.remote, {}).setdefault(install.pin, name)
        return grouped

    @staticmethod
    def backing_paths(world: World, kind: str = RELEASE_KIND) -> dict[str, str]:
        """Install path -> the entry naming it."""
        return {install.path: name for name, install in declarations.reusable(world, kind).items()}

    @staticmethod
    def resolved_by(world: World, path: str, kind: str = RELEASE_KIND) -> Optional[Install]:
        """The declared install an entry path resolves to, if any. Undeclared
        is deliberately not the same as absent - see the declaration invariant."""
        entry = world.entries.get(path)
        backing = entry.backing if entry else None
        if backing and backing in declarations.backing_paths(world, kind):
            return declarations.everything(world)[backing]
        return None

    @staticmethod
    def effective_pin(
        world: World, dependent: Pin, entry_name: str, demanded: Pin, kind: str = RELEASE_KIND
    ) -> Pin:
        """What this edge actually resolves to today: the consumer's own
        resolution if they declared one, otherwise what was asked for."""
        return declarations.resolved_edge(world, dependent, entry_name, kind) or demanded

    @staticmethod
    def resolved_edge(
        world: World, dependent: Pin, entry_name: str, kind: str = RELEASE_KIND
    ) -> Optional[Pin]:
        for path in declarations._sibling_candidates(world, dependent, entry_name):
            install = declarations.resolved_by(world, path, kind)
            if install:
                return install.pin
        return None

    @staticmethod
    def _sibling_candidates(world: World, dependent: Pin, entry_name: str) -> tuple[str, ...]:
        homes = {os.path.dirname(path)
                 for path, install in declarations.everything(world).items()
                 if install.pin == dependent}
        homes.add("")
        return tuple(os.path.join(home, entry_name) if home else entry_name
                     for home in sorted(homes))

    @staticmethod
    def classify(world: World, install: Install) -> str:
        if install.path in world.vendored:
            return VENDORED_KIND
        if install.path in declarations.backing_paths(world):
            return RELEASE_KIND
        return DEVELOPMENT_KIND


# --------------------------------------------------------------------------- #
# 9. stage() - the last I/O before the planner                                 #
# --------------------------------------------------------------------------- #


@dataclass(frozen=True)
class Staged:
    manifests: Mapping[Pin, Manifest] = field(default_factory=dict[Pin, Manifest])
    trees: Mapping[Pin, str] = field(default_factory=dict[Pin, str])  # pin -> directory holding its bytes
    ancestry: Mapping[tuple[str, str], bool] = field(default_factory=dict[tuple[str, str], bool])


def stage(
    world: World, pins: Sequence[Pin], use_cache: bool = True, kind: str = RELEASE_KIND
) -> Staged:
    """Fetch every pin in the closure into `.git/suede-cache/` and read its
    manifest from there. Staging before planning is what lets the announce
    block name a dependency's dependencies before anything is installed."""
    cache.prune(world.root)
    installed = _installed_manifests(world)
    reusable = _reusable_manifests(world, installed, kind)
    manifests: dict[Pin, Manifest] = {}
    trees: dict[Pin, str] = {}
    queue = deque(pins)
    while queue:
        pin = queue.popleft()
        if pin in manifests:
            continue
        manifests[pin] = reusable.get(pin) or _fetch(world, pin, trees, use_cache)
        queue.extend(_wanted_by(world, pin, manifests[pin], kind))
    manifests.update({pin: manifest for pin, manifest in installed.items() if pin not in manifests})
    return Staged(manifests=manifests, trees=trees, ancestry=_ancestry(world, manifests, use_cache))


def _installed_manifests(world: World) -> dict[Pin, Manifest]:
    """An installed copy is authoritative for its own manifest and saves a
    clone, which is what makes a re-run on a satisfied tree work offline."""
    return {
        install.pin: gitrepo.read_manifest(os.path.join(world.root, install.path))
        for install in declarations.everything(world).values()
    }


def _reusable_manifests(
    world: World, installed: Mapping[Pin, Manifest], kind: str
) -> dict[Pin, Manifest]:
    """Of those, the ones this run may read *instead of* fetching.

    A copy this run cannot point an edge at is a copy it is going to install
    somewhere else - vendoring one that sits at the repo root, say - and that
    needs the pin's own bytes. Reading its manifest without fetching would
    leave apply with nothing to copy, and copying the local folder instead
    would write a pointer to a commit those bytes may no longer match.
    """
    return {
        install.pin: installed[install.pin]
        for install in declarations.reusable(world, kind).values()
        if install.pin in installed
    }


def _fetch(world: World, pin: Pin, trees: dict[Pin, str], use_cache: bool) -> Manifest:
    trees[pin] = cache.fetch(world.root, pin, use_cache)
    return gitrepo.read_manifest(trees[pin])


def _wanted_by(world: World, dependent: Pin, manifest: Manifest, kind: str) -> list[Pin]:
    """Following the consumer's own resolution here is what keeps staging from
    cloning a dependency they have already replaced."""
    return [
        declarations.effective_pin(world, dependent, entry_name, demanded, kind)
        for entry_name, demanded in sorted(manifest.edges.items())
    ]


class cache:
    """`.git/suede-cache/` - under `.git/`, so it can never be committed and
    needs no .gitignore entry."""

    @staticmethod
    def directory(root: str) -> str:
        return os.path.join(root, CACHE_DIR)

    @staticmethod
    def fetch(root: str, pin: Pin, use_cache: bool) -> str:
        destination = os.path.join(cache.directory(root), pin.short)
        if os.path.isdir(destination) and use_cache:
            return destination
        shutil.rmtree(destination, ignore_errors=True)
        try:
            git.fetch_commit(pin.remote, pin.commit, pin.branch, destination)
        except SuedeError as failure:
            shutil.rmtree(destination, ignore_errors=True)
            raise SuedeError(_unreachable(pin, failure))
        return destination

    @staticmethod
    def history(root: str, remote: str, branch: str) -> Optional[str]:
        destination = os.path.join(cache.directory(root), "history", _slug(remote) + ".git")
        if os.path.isdir(destination):
            return destination
        try:
            git.fetch_history(remote, branch, destination)
        except SuedeError:
            shutil.rmtree(destination, ignore_errors=True)
            return None
        return destination

    @staticmethod
    def prune(root: str) -> None:
        directory = cache.directory(root)
        if not os.path.isdir(directory):
            return
        cutoff = time.time() - CACHE_MAX_AGE_SECONDS
        for name in os.listdir(directory):
            entry = os.path.join(directory, name)
            if os.path.isdir(entry) and os.path.getmtime(entry) < cutoff:
                shutil.rmtree(entry, ignore_errors=True)


def _unreachable(pin: Pin, failure: SuedeError) -> str:
    return (
        "could not fetch %s@%s from %s.\n"
        "  A private repository needs an SSH key - `ssh -T git@<host>` should greet\n"
        "  you by name. A public one needs none, but a credential helper that has\n"
        "  never seen the host can still prompt; `git clone` it once by hand to\n"
        "  settle that. If the repository has no `%s` branch it is not a published\n"
        "  suede dependency yet.\n%s"
        % (pin.name, pin.short, pin.remote, pin.branch, failure)
    )


def _slug(remote: str) -> str:
    return "".join(character if character.isalnum() else "-" for character in remote).strip("-")


def _ancestry(
    world: World, manifests: Mapping[Pin, Manifest], use_cache: bool
) -> dict[tuple[str, str], bool]:
    """"Newer" is a question about history, never about dates - so answer it
    with `merge-base`, and only for the remotes that actually disagree."""
    table: dict[tuple[str, str], bool] = {}
    for remote, pins in _remotes_wanted_twice(world, manifests).items():
        repository = cache.history(world.root, remote, pins[0].branch) if use_cache else None
        if not repository:
            continue
        for older in pins:
            for newer in pins:
                if older != newer:
                    table[(older.commit, newer.commit)] = git.is_ancestor(
                        older.commit, newer.commit, cwd=repository
                    )
    return table


def _remotes_wanted_twice(
    world: World, manifests: Mapping[Pin, Manifest]
) -> dict[str, list[Pin]]:
    by_remote: dict[str, list[Pin]] = {}
    for pin in _every_pin(world, manifests):
        by_remote.setdefault(pin.remote, [])
        if pin not in by_remote[pin.remote]:
            by_remote[pin.remote].append(pin)
    return {remote: pins for remote, pins in by_remote.items() if len(pins) > 1}


def _every_pin(world: World, manifests: Mapping[Pin, Manifest]) -> Iterable[Pin]:
    for install in declarations.everything(world).values():
        yield install.pin
    for pin, manifest in manifests.items():
        yield pin
        for demanded in manifest.edges.values():
            yield demanded


# --------------------------------------------------------------------------- #
# 10. plan() - pure                                                            #
# --------------------------------------------------------------------------- #


@dataclass(frozen=True)
class Demand:
    """An edge, before either end of it has a place on disk."""

    dependent: Pin
    entry_name: str
    pin: Pin  # what the dependent asked for
    substitute: Optional[Pin] = None  # what the consumer already backed it with

    @property
    def effective(self) -> Pin:
        return self.substitute or self.pin


class Names:
    """Allocates root entry names. An existing entry is never renamed - the
    project's own imports of `../app.C` are invisible from here - so a
    newcomer that wants a taken name gets the suffix instead."""

    def __init__(self, taken: Iterable[str]):
        self._taken: set[str] = set(taken)

    def clone(self) -> "Names":
        return Names(self._taken)

    def reserve(self, preferred: str, distinguisher: str) -> str:
        name = preferred if preferred not in self._taken else preferred + "-" + distinguisher
        attempt = 2
        while name in self._taken:
            name = "%s-%s-%d" % (preferred, distinguisher, attempt)
            attempt += 1
        self._taken.add(name)
        return name


@dataclass
class Resolution:
    """Which entry backs each pin, and what remains unresolved."""

    entry_of: dict[Pin, str] = field(default_factory=dict)
    pin_of_entry: dict[str, Pin] = field(default_factory=dict)
    installs: list[tuple[Pin, str]] = field(default_factory=list)
    reuses: list[tuple[Pin, str]] = field(default_factory=list)
    conflicts: list[Conflict] = field(default_factory=list)

    def satisfy(self, pin: Pin, entry: str, backed_by: Pin) -> None:
        self.entry_of[pin] = entry
        self.pin_of_entry[entry] = backed_by

    def place(self, pin: Pin, entry: str) -> None:
        self.installs.append((pin, entry))
        self.satisfy(pin, entry, pin)


def plan(
    world: World,
    request: Request,
    policy: Policy,
    manifests: Mapping[Pin, Manifest],
    ancestry: Optional[Mapping[tuple[str, str], bool]] = None,
) -> Plan:
    blockers = _preconditions(world, request)
    if blockers:
        return Plan(blockers=blockers)
    merge = _package_merge(world, policy, manifests, request.kind)
    pins, demands = _closure(world, request, manifests)
    resolution = _resolve(world, request, policy, pins, demands, ancestry or {})
    acts, warnings = _acts(world, request, demands, resolution, merge.acts)
    return Plan(
        acts=_ordered(acts),
        conflicts=tuple(sorted(resolution.conflicts, key=lambda conflict: conflict.remote)),
        warnings=tuple(warnings)
        + tuple(_legacy_manifest_warnings(manifests))
        + merge.warnings
        + _situational_warnings(world, request),
        blockers=merge.blockers,
    )


def _preconditions(world: World, request: Request) -> tuple[str, ...]:
    if world.head is None:
        return (
            "this repository has no commits yet. Install would write an empty `parent`"
            " into every .gitrepo and the first `git subrepo pull` would fail with"
            " 'refusing to merge unrelated histories'. Commit something first.",
        )
    if request.kind == VENDORED_KIND and not world.has_release:
        return (
            "vendoring ships the dependency's source with your release branch, and this"
            " project has no %s/ directory to ship it in. Install it as a release"
            " dependency, or as a development one with --dev." % RELEASE_DIR,
        )
    return ()


def _closure(
    world: World, request: Request, manifests: Mapping[Pin, Manifest]
) -> tuple[tuple[Pin, ...], tuple[Demand, ...]]:
    """Every pin reachable from the request, and the demand that reached it.
    The visited set is what makes a cycle terminate rather than a promise."""
    pins: list[Pin] = []
    demands: list[Demand] = []
    queue = deque(request.pins)
    while queue:
        pin = queue.popleft()
        if pin in pins:
            continue
        pins.append(pin)
        for entry_name in sorted(manifests.get(pin, EMPTY_MANIFEST).edges):
            demand = _demand(world, pin, entry_name, manifests[pin].edges[entry_name], request.kind)
            demands.append(demand)
            queue.append(demand.effective)
    return tuple(pins), tuple(demands)


def _demand(world: World, dependent: Pin, entry_name: str, demanded: Pin, kind: str) -> Demand:
    """A consumer who has already backed this edge with a declared entry of
    their own has resolved it - a fork, a patched build, their own
    implementation. Follow their resolution, do not re-flatten ours."""
    effective = declarations.effective_pin(world, dependent, entry_name, demanded, kind)
    return Demand(
        dependent=dependent,
        entry_name=entry_name,
        pin=demanded,
        substitute=effective if effective != demanded else None,
    )


def _resolve(
    world: World,
    request: Request,
    policy: Policy,
    pins: Sequence[Pin],
    demands: Sequence[Demand],
    ancestry: Mapping[tuple[str, str], bool],
) -> Resolution:
    resolution = Resolution()
    naming = Naming(
        repo=world.repo,
        sep=world.sep,
        kind=request.kind,
        override=request.name,
        requested=request.pins,
        commit_suffix=request.commit_suffix,
        edge_names=_edge_names(demands) if request.edge_named else {},
    )
    names = Names(declarations.taken_names(world, request.kind))
    declared = declarations.by_remote(world, request.kind)
    wanted_by_remote = _wanted_by_remote(pins)
    for remote in sorted(wanted_by_remote):
        _resolve_remote(
            remote=remote,
            wanted=wanted_by_remote[remote],
            declared=declared.get(remote, {}),
            claims=_claims(remote, request, demands),
            involves_root=any(pin.remote == remote for pin in request.pins),
            naming=naming,
            policy=policy,
            ancestry=ancestry,
            names=names,
            resolution=resolution,
        )
    return resolution


def _edge_names(demands: Sequence[Demand]) -> dict[Pin, str]:
    """The entry name each pin is *first* asked for by.

    Demands arrive in closure order, so the dependent nearest the request wins
    the folder and everything asking for the same pin later gets the link. The
    name is the manifest filename verbatim - the one thing that is already
    fixed, by the dependent's authors, in the dependent's own separator.
    """
    names: dict[Pin, str] = {}
    for demand in demands:
        names.setdefault(demand.effective, demand.entry_name)
    return names


def _wanted_by_remote(pins: Sequence[Pin]) -> dict[str, list[Pin]]:
    wanted: dict[str, list[Pin]] = {}
    for pin in pins:
        wanted.setdefault(pin.remote, [])
        if pin not in wanted[pin.remote]:
            wanted[pin.remote].append(pin)
    return wanted


def _claims(remote: str, request: Request, demands: Sequence[Demand]) -> tuple[Claim, ...]:
    claims = [Claim(dependent=None, pin=pin) for pin in request.pins if pin.remote == remote]
    claims += [
        Claim(dependent=demand.dependent.name, pin=demand.effective)
        for demand in demands
        if demand.effective.remote == remote
    ]
    return tuple(sorted(claims, key=lambda claim: (claim.dependent or "", claim.pin.commit)))


def _resolve_remote(
    remote: str,
    wanted: Sequence[Pin],
    declared: Mapping[Pin, str],
    claims: tuple[Claim, ...],
    involves_root: bool,
    naming: Naming,
    policy: Policy,
    ancestry: Mapping[tuple[str, str], bool],
    names: Names,
    resolution: Resolution,
) -> None:
    unmatched = _reuse_exact_matches(wanted, declared, resolution)
    if not unmatched:
        return
    if len(declared) == 1:
        _defer_to_the_consumer(unmatched, declared, resolution)
        return
    if len(declared) > 1:
        resolution.conflicts.append(_ambiguous(remote, claims, declared, involves_root))
        return
    if len(unmatched) == 1:
        resolution.place(
            unmatched[0], names.reserve(naming.preferred(unmatched[0]), unmatched[0].short)
        )
        return
    _resolve_competing_commits(
        remote, unmatched, claims, involves_root, naming, policy, ancestry, names, resolution
    )


def _reuse_exact_matches(
    wanted: Sequence[Pin], declared: Mapping[Pin, str], resolution: Resolution
) -> list[Pin]:
    """An exact commit match is always the answer, whatever else is declared."""
    unmatched: list[Pin] = []
    for pin in wanted:
        if pin in declared:
            resolution.satisfy(pin, declared[pin], pin)
            resolution.reuses.append((pin, declared[pin]))
        else:
            unmatched.append(pin)
    return unmatched


def _defer_to_the_consumer(
    unmatched: Sequence[Pin], declared: Mapping[Pin, str], resolution: Resolution
) -> None:
    """Exactly one root-declared entry for this remote and no exact match: the
    consumer has already resolved it. Their declaration wins - announce it."""
    entry = list(declared.values())[0]
    backing = list(declared.keys())[0]
    for pin in unmatched:
        resolution.satisfy(pin, entry, backing)


def _resolve_competing_commits(
    remote: str,
    unmatched: Sequence[Pin],
    claims: tuple[Claim, ...],
    involves_root: bool,
    naming: Naming,
    policy: Policy,
    ancestry: Mapping[tuple[str, str], bool],
    names: Names,
    resolution: Resolution,
) -> None:
    conflict = _conflict(remote, unmatched, claims, involves_root, naming, ancestry, names)
    chosen = _policy_choice(policy, conflict, ancestry)
    if chosen is None:
        resolution.conflicts.append(conflict)
        return
    _adopt(chosen, names, resolution)


def _adopt(option: Option, names: Names, resolution: Resolution) -> None:
    for pin, entry in option.placements:
        names.reserve(entry, pin.short)
        resolution.installs.append((pin, entry))
    for pin, entry in option.assignments:
        resolution.satisfy(pin, entry, _placed_pin(option, entry))


def _placed_pin(option: Option, entry: str) -> Pin:
    for pin, placed in option.placements:
        if placed == entry:
            return pin
    if option.backed_by:
        return option.backed_by
    raise PlanError("option %s assigns %s with nothing installed there" % (option.id, entry))


def _policy_choice(
    policy: Policy, conflict: Conflict, ancestry: Mapping[tuple[str, str], bool]
) -> Optional[Option]:
    if conflict.remote in policy.choices:
        return _chosen(conflict, policy.choices[conflict.remote])
    if conflict.kind == "ambiguous":
        return None  # which declared entry was meant is not a thing to guess
    if policy.on_conflict == "coexist":
        return _option_by_id(conflict, "coexist")
    if policy.on_conflict == "unify-newest":
        return _newest_unify_option(conflict, ancestry)
    return None


def _chosen(conflict: Conflict, index: int) -> Optional[Option]:
    option = conflict.options[index]
    return None if option.id == "defer" else option


def _option_by_id(conflict: Conflict, wanted: str) -> Optional[Option]:
    for option in conflict.options:
        if option.id == wanted:
            return option
    return None


def _newest_unify_option(
    conflict: Conflict, ancestry: Mapping[tuple[str, str], bool]
) -> Optional[Option]:
    unifications = [option for option in conflict.options if option.id == "unify"]
    newest = _newest([option.pin for option in unifications if option.pin], ancestry)
    if newest is None:
        return None
    return next(option for option in unifications if option.pin == newest)


def _newest(pins: Sequence[Pin], ancestry: Mapping[tuple[str, str], bool]) -> Optional[Pin]:
    """The one every other commit is an ancestor of. Diverged history has no
    newest, and guessing one is how a dependent silently gets a commit its
    author never tested."""
    for candidate in pins:
        others = [pin for pin in pins if pin != candidate]
        if all(ancestry.get((pin.commit, candidate.commit)) for pin in others):
            return candidate
    return None


# --------------------------------------------------------------------------- #
# 11. Conflict options - pure                                                  #
# --------------------------------------------------------------------------- #


def _conflict(
    remote: str,
    unmatched: Sequence[Pin],
    claims: tuple[Claim, ...],
    involves_root: bool,
    naming: Naming,
    ancestry: Mapping[tuple[str, str], bool],
    names: Names,
) -> Conflict:
    return Conflict(
        remote=remote,
        claims=claims,
        ancestry=_describe_ancestry(unmatched, ancestry),
        options=_options(unmatched, claims, naming, ancestry, names),
        involves_root=involves_root,
    )


def _describe_ancestry(pins: Sequence[Pin], ancestry: Mapping[tuple[str, str], bool]) -> str:
    if len(pins) != 2:
        return "unknown"
    first, second = pins[0].commit, pins[1].commit
    if (first, second) not in ancestry and (second, first) not in ancestry:
        return "unknown"
    if ancestry.get((first, second)):
        return "ancestor"
    if ancestry.get((second, first)):
        return "descendant"
    return "diverged"


def _options(
    unmatched: Sequence[Pin],
    claims: tuple[Claim, ...],
    naming: Naming,
    ancestry: Mapping[tuple[str, str], bool],
    names: Names,
) -> tuple[Option, ...]:
    """Every option states its concrete filesystem outcome and its own risk.
    Nothing is preselected; when the root project is a claimant, coexist leads,
    because unifying changes what its own source compiles against."""
    offers = [_coexist(unmatched, naming, names)]
    offers += [
        _unify(pin, unmatched, claims, naming, names) for pin in _newest_first(unmatched, ancestry)
    ]
    offers.append(_defer())
    return tuple(offers)


def _newest_first(pins: Sequence[Pin], ancestry: Mapping[tuple[str, str], bool]) -> list[Pin]:
    newest = _newest(pins, ancestry)
    if newest is None:
        return list(pins)
    return [newest] + [pin for pin in pins if pin != newest]


def _coexist(unmatched: Sequence[Pin], naming: Naming, names: Names) -> Option:
    scratch = names.clone()
    placements = tuple(
        (pin, scratch.reserve(naming.preferred(pin), pin.short)) for pin in unmatched
    )
    return Option(
        id="coexist",
        label="two installs, each dependent keeps its own pin",
        risk="two runtime copies - breaks singletons, instanceof, shared framework context",
        placements=placements,
        assignments=placements,
    )


def _unify(
    pin: Pin, unmatched: Sequence[Pin], claims: tuple[Claim, ...], naming: Naming, names: Names
) -> Option:
    entry = names.clone().reserve(naming.preferred(pin), pin.short)
    return Option(
        id="unify",
        label="one install at %s; every dependent points at it" % pin.short,
        risk=_unify_risk(pin, claims),
        placements=((pin, entry),),
        assignments=tuple((wanted, entry) for wanted in unmatched),
        pin=pin,
    )


def _unify_risk(pin: Pin, claims: tuple[Claim, ...]) -> str:
    losers = sorted({claim.dependent or "this project" for claim in claims if claim.pin != pin})
    if not losers:
        return ""
    return "%s was built and tested against a different commit" % ", ".join(losers)


def _defer() -> Option:
    return Option(
        id="defer",
        label="install nothing here; print what is needed",
        risk="",
    )




def _ambiguous(
    remote: str, claims: tuple[Claim, ...], declared: Mapping[Pin, str], involves_root: bool
) -> Conflict:
    """Several root-declared entries share this remote and none matches the
    commit asked for. Coexist installs are only resolvable downstream because
    we prompt here instead of guessing which one was meant."""
    return Conflict(
        remote=remote,
        claims=claims,
        ancestry="unknown",
        options=tuple(
            [
                Option(
                    id="existing",
                    label="satisfy from the declared entry %s" % entry,
                    risk="that entry pins %s" % pin.short,
                    assignments=tuple((claim.pin, entry) for claim in claims),
                    backed_by=pin,
                    pin=pin,
                )
                for pin, entry in sorted(declared.items(), key=lambda item: item[1])
            ]
            + [_defer()]
        ),
        involves_root=involves_root,
        kind="ambiguous",
    )


# --------------------------------------------------------------------------- #
# 12. Acts - pure                                                              #
# --------------------------------------------------------------------------- #


def _acts(
    world: World,
    request: Request,
    demands: Sequence[Demand],
    resolution: Resolution,
    package_acts: Sequence[Act],
) -> tuple[list[Act], list[str]]:
    layout = Layout(kind=request.kind, target=request.target, link_mode=request.link_mode)
    edges, warnings = _edge_acts(world, demands, resolution, layout)
    acts = (
        _install_acts(request, demands, resolution, layout)
        + _reuse_acts(world, resolution, layout.kind)
        + edges
        + _record_acts(world, resolution, layout.kind)
        + list(package_acts)
    )
    return _drop_notes_when_nothing_changes(acts), warnings


def _drop_notes_when_nothing_changes(acts: list[Act]) -> list[Act]:
    """`reuse` and `override` explain a change; with no change to explain, a
    re-run on a satisfied tree should say nothing at all."""
    return acts if any(act.op in MUTATING_OPS for act in acts) else []


def _install_acts(
    request: Request, demands: Sequence[Demand], resolution: Resolution, layout: Layout
) -> list[Act]:
    return [
        Act(
            op="install",
            entry=entry,
            pin=pin,
            dest=layout.install_path(entry),
            reason=_why(pin, request, demands),
        )
        for pin, entry in resolution.installs
    ]


def _why(pin: Pin, request: Request, demands: Sequence[Demand]) -> str:
    if pin in request.pins:
        return "requested"
    for demand in demands:
        if demand.effective == pin:
            return "required by " + demand.dependent.name
    return "flattening"


def _reuse_acts(world: World, resolution: Resolution, kind: str) -> list[Act]:
    declared = declarations.reusable(world, kind)
    return [
        Act(
            op="reuse",
            entry=entry,
            pin=pin,
            dest=declared[entry].path if entry in declared else entry,
            reason="already present",
        )
        for pin, entry in resolution.reuses
    ]


def _edge_acts(
    world: World, demands: Sequence[Demand], resolution: Resolution, layout: Layout
) -> tuple[list[Act], list[str]]:
    acts: list[Act] = []
    warnings: list[str] = []
    for demand in demands:
        acts += _override_act(demand, resolution)
        for path in _edge_paths(world, demand, resolution, layout):
            act, warning = _one_edge(world, path, demand, resolution, layout)
            acts += act
            warnings += warning
    return acts, warnings


def _edge_paths(
    world: World, demand: Demand, resolution: Resolution, layout: Layout
) -> tuple[str, ...]:
    dependent = resolution.entry_of.get(demand.dependent)
    if dependent is None or demand.effective not in resolution.entry_of:
        return ()
    home = os.path.dirname(_where(world, dependent, layout))
    return layout.edge_paths(home, demand.entry_name)


def _one_edge(
    world: World, path: str, demand: Demand, resolution: Resolution, layout: Layout
) -> tuple[list[Act], list[str]]:
    install = _where(world, resolution.entry_of[demand.effective], layout)
    if path == install:
        # Edge naming put the bytes where the link would have gone: the entry
        # the dependent asks for *is* the install.
        return [], []
    existing = world.entries.get(path)
    if existing is None:
        return [_link(layout, path, install)], []
    if existing.backing == install:
        return [], []
    return [], [_resolved_elsewhere(path, existing, install)]


def _link(layout: Layout, path: str, install: str) -> Act:
    return Act(op=layout.link_mode_op, entry=path, target=relative_link(path, install), dest=install)


def _resolved_elsewhere(path: str, existing: Entry, install: str) -> str:
    return "%s already exists and resolves to %s, not %s - left untouched; run `suede check`" % (
        path,
        existing.backing or "nothing",
        install,
    )


def _where(world: World, entry: str, layout: Layout) -> str:
    """The directory an entry names: where it already is, or where it will go."""
    declared = declarations.reusable(world, layout.kind)
    if entry in declared:
        return declared[entry].path
    return layout.install_path(entry)


def _override_act(demand: Demand, resolution: Resolution) -> list[Act]:
    """A consumer who resolved an edge differently gets told, not challenged."""
    entry = resolution.entry_of.get(demand.effective)
    backing = resolution.pin_of_entry.get(entry) if entry else None
    if backing is None or backing == demand.pin:
        return []
    return [
        Act(
            op="override",
            entry=demand.entry_name,
            pin=demand.pin,
            target=entry,
            reason="%s pins %s; you declare %s"
            % (demand.dependent.name, demand.pin.short, backing.short),
        )
    ]


def _record_acts(world: World, resolution: Resolution, kind: str) -> list[Act]:
    """A project records its whole transitive closure as its own release
    dependencies - which is what makes its manifest a complete recipe.

    Only a release install is recorded. A development one is invisible to the
    release branch by definition, and a vendored one ships its bytes rather
    than a pointer to them - recording either would advertise to consumers a
    dependency they must resolve and, in the vendored case, already have.
    """
    if not world.has_release or kind != RELEASE_KIND:
        return []
    return [
        Act(
            op="record",
            entry=entry,
            pin=pin,
            dest=os.path.join(RELEASE_DIR, MANIFEST_DIR, entry + GITREPO),
        )
        for entry, pin in sorted(resolution.pin_of_entry.items())
        if world.records.get(entry) != pin
    ]


@dataclass(frozen=True)
class Ecosystem:
    """One package manager's half of the merge. Both halves work the same way -
    take what a dependency declares, add what is missing, refuse to guess at
    what disagrees - so they differ only in where the declarations live and how
    a single one of them reads."""

    op: str  # the act's op, and the word the plan prints
    noun: str  # how a blocker names one of its packages
    file: str  # the consumer file the merge writes into
    section: str  # the block within it, where the file has blocks
    declares: str  # where a blocker says your own declaration lives
    declared: Callable[[World], Mapping[str, str]]
    wanted: Callable[[Manifest], Mapping[str, str]]
    enabled: Callable[[Policy], bool]
    render: Callable[[str, str], str]  # package, declaration -> the act's entry


def ecosystems(kind: str) -> tuple[Ecosystem, ...]:
    """Where this kind of install's packages go.

    A development dependency's packages are not the project's own, and
    `extract` publishes `dependencies` and requirements.txt verbatim - so
    merging them there would hand every consumer a package only your test
    harness ever imports. They go to the dev half of each ecosystem instead,
    which nothing publishes.

    What counts as *already declared* widens to match: a package your
    `dependencies` already names must not be declared a second time under
    `devDependencies`, whatever the version.
    """
    dev = kind == DEVELOPMENT_KIND
    return (
        Ecosystem(
            op="npm",
            noun="npm dependency",
            file=PACKAGE_JSON,
            section=NPM_DEV_SECTION if dev else NPM_SECTION,
            declares=PACKAGE_JSON,
            declared=(lambda world: dict(world.npm, **dict(world.npm_dev))) if dev
            else (lambda world: world.npm),
            wanted=lambda manifest: manifest.npm,
            enabled=lambda policy: policy.npm,
            render=lambda package, declaration: "%s@%s" % (package, declaration),
        ),
        Ecosystem(
            op="pip",
            noun="python dependency",
            file=DEV_REQUIREMENTS if dev else REQUIREMENTS,
            section="",
            # A dev merge is measured against both files, so a blocker must not
            # claim the declaration is in the one it would have written to.
            declares="%s or %s" % (REQUIREMENTS, DEV_REQUIREMENTS) if dev else REQUIREMENTS,
            declared=(lambda world: dict(world.python, **dict(world.python_dev))) if dev
            else (lambda world: world.python),
            wanted=lambda manifest: manifest.python,
            enabled=lambda policy: policy.python,
            # A requirement is already one string. Splitting it into name and
            # specifier only to paste it back together is how extras and markers
            # get lost, so the whole line travels.
            render=lambda _package, declaration: declaration,
        ),
    )


@dataclass(frozen=True)
class PackageMerge:
    """What merging every dependency's package declarations comes to."""

    acts: tuple[Act, ...] = ()
    warnings: tuple[str, ...] = ()
    blockers: tuple[str, ...] = ()


def _package_merge(
    world: World, policy: Policy, manifests: Mapping[Pin, Manifest], kind: str = RELEASE_KIND
) -> PackageMerge:
    acts: list[Act] = []
    warnings: list[str] = []
    conflicts: list[str] = []
    for ecosystem in ecosystems(kind):
        additions, disagreements, rivals = _package_diff(ecosystem, world, policy, manifests)
        acts += [
            Act(
                op=ecosystem.op,
                entry=ecosystem.render(package, wanted),
                dest=ecosystem.file,
                section=ecosystem.section,
                reason="new" if kind != DEVELOPMENT_KIND else "new in " + (
                    ecosystem.section or ecosystem.file
                ),
            )
            for package, wanted in sorted(additions.items())
        ]
        warnings += rivals
        conflicts += _conflict_sentences(ecosystem, disagreements)
    if policy.python:
        warnings += _unmergeable_requirement_warnings(manifests)
    if conflicts and policy.allow_package_conflicts:
        # The install proceeds and your file is left exactly as it was. Saying
        # so is the point: the dependency is now running against a version you
        # chose and it never saw.
        return PackageMerge(tuple(acts), tuple(warnings + _kept_sentences(conflicts)), ())
    return PackageMerge(tuple(acts), tuple(warnings), tuple(_blocked(conflicts)))


def _package_diff(
    ecosystem: Ecosystem, world: World, policy: Policy, manifests: Mapping[Pin, Manifest]
) -> tuple[dict[str, str], dict[str, tuple[str, str]], list[str]]:
    """Missing packages are additions; a declaration that disagrees with yours
    is a conflict, and unifying two version ranges is a different problem with
    its own semantics.

    Two dependencies disagreeing with each other is not that problem: neither
    range is yours, nothing of yours is at stake, and refusing to install would
    leave you with no way to reconcile them. The first in pin order wins and
    the rest are reported.
    """
    additions: dict[str, str] = {}
    conflicts: dict[str, tuple[str, str]] = {}
    rivals: list[str] = []
    if not ecosystem.enabled(policy):
        return additions, conflicts, rivals
    declared_here = ecosystem.declared(world)
    asked_by: dict[str, str] = {}
    for pin, manifest in sorted(manifests.items()):
        for package, wanted in sorted(ecosystem.wanted(manifest).items()):
            declared = declared_here.get(package)
            if declared is not None:
                if declared != wanted:
                    conflicts[package] = (wanted, declared)
                continue
            if additions.setdefault(package, wanted) != wanted:
                rivals.append(
                    "%s %s: %s asks for %s, %s asks for %s. Adding %s - reconcile them yourself."
                    % (
                        ecosystem.noun,
                        package,
                        asked_by[package],
                        additions[package],
                        pin.name,
                        wanted,
                        additions[package],
                    )
                )
                continue
            asked_by.setdefault(package, pin.name)
    return additions, conflicts, rivals


def _conflict_sentences(
    ecosystem: Ecosystem, disagreements: Mapping[str, tuple[str, str]]
) -> list[str]:
    return [
        "%s %s: a dependency asks for %s, your %s declares %s."
        % (ecosystem.noun, package, wanted, ecosystem.declares, declared)
        for package, (wanted, declared) in sorted(disagreements.items())
    ]


def _blocked(conflicts: Sequence[str]) -> list[str]:
    if not conflicts:
        return []
    return list(conflicts) + [
        "Unify the versions yourself - suede will not guess - or re-run with %s to keep"
        " your own declarations and install the rest anyway." % ALLOW_CONFLICTS_FLAG
    ]


def _kept_sentences(conflicts: Sequence[str]) -> list[str]:
    return [conflict + " Kept yours (%s)." % ALLOW_CONFLICTS_FLAG for conflict in conflicts]


def _unmergeable_requirement_warnings(manifests: Mapping[Pin, Manifest]) -> list[str]:
    """A requirements.txt is not only requirements. Options and bare URLs name
    no package, so there is nothing to compare or merge - but a dependency that
    needs one needs it whether or not suede can carry it across."""
    return [
        "%s publishes requirements.txt lines that name no package, so they are not merged: %s."
        " Copy them into your own requirements.txt if you need them."
        % (pin.name, ", ".join(manifest.python_extras))
        for pin, manifest in sorted(manifests.items())
        if manifest.python_extras
    ]


def _legacy_manifest_warnings(manifests: Mapping[Pin, Manifest]) -> list[str]:
    """Its entry names were chosen before the `$repo$SEP` rule, so the siblings
    it asks for are not the ones its own code imports. Reading it is better
    than being blind, but only republishing fixes it."""
    return [
        "%s publishes its manifest at the pre-2.0 path (%s). Its entry names predate the"
        " $repo$SEP rule, so what it asks for may not match what its code imports."
        " Run `suede extract` on that dependency and republish it."
        % (pin.name, LEGACY_MANIFEST_DIR)
        for pin, manifest in sorted(manifests.items())
        if manifest.legacy
    ]


def _situational_warnings(world: World, request: Request) -> tuple[str, ...]:
    warnings: list[str] = []
    if world.dirty:
        warnings.append(
            "working tree is dirty. Install is fine with that, but `git subrepo pull` is not."
        )
    if request.target:
        warnings.append(
            "--target relocates the real install. Edge entries are written both beside it and at"
            " the repo root, because Node dereferences symlinks and bundlers with preserveSymlinks"
            " do not. If your build resolves neither, you own the fix."
        )
    if request.kind == VENDORED_KIND:
        # Everything under release/ is what this run is *about*, so the notice
        # below would report the plan back as a surprise.
        return tuple(warnings) + _vendoring_notes(request)
    for path in world.vendored:
        if declarations.is_machinery(path):
            continue
        warnings.append("%s is vendored inside release/ - it ships as source, nothing to install" % path)
    return tuple(warnings)


def _vendoring_notes(_request: Request) -> tuple[str, ...]:
    """What vendoring costs, said once at the point of choosing it."""
    return (
        "vendored code ships with your release branch, .gitrepo included - so consumers get a"
        " nested subrepo, and `suede diff` will not police it against its pin (that is the"
        " point of vendoring). Point your release/ imports at the paths above.",
    )


def _ordered(acts: list[Act]) -> tuple[Act, ...]:
    return tuple(sorted(acts, key=lambda act: (OP_ORDER.index(act.op), act.entry)))


# --------------------------------------------------------------------------- #
# 13. announce() and plan_json() - pure                                        #
# --------------------------------------------------------------------------- #


def announce(world: World, plan: Plan, request: Request, evidence: str = "") -> str:
    lines = _header(world, request, evidence)
    if plan.blockers:
        return "\n".join(lines + _titled("BLOCKED", plan.blockers))
    lines += _act_lines(plan)
    lines += _conflict_lines(plan)
    lines += _titled("WARNINGS", plan.warnings)
    return "\n".join(lines)


def _titled(title: str, lines: Sequence[str]) -> list[str]:
    if not lines:
        return []
    return [title, ""] + ["  " + line for line in lines] + [""]


KIND_NOTES = {
    RELEASE_KIND: "release dependency - recorded in %s, shipped as a pointer"
    % os.path.join(RELEASE_DIR, MANIFEST_DIR),
    DEVELOPMENT_KIND: "development dependency - unprefixed, never recorded, never shipped",
    VENDORED_KIND: "vendored release dependency - ships as source inside %s/" % RELEASE_DIR,
}


def _header(world: World, request: Request, evidence: str) -> list[str]:
    subject = ", ".join(pin.name for pin in request.pins) or world.repo
    return [
        "suede - %s" % subject,
        "",
        "  repo:       %s" % world.repo,
        "  separator:  %s          (%s)" % (world.sep, _separator_note(world, evidence)),
        "  kind:       %s" % KIND_NOTES.get(request.kind, request.kind),
        "  layout:     %s" % _layout_note(request),
        "",
    ]


def _layout_note(request: Request) -> str:
    where = "%s/ (vendored)" % VENDOR_DIR if request.kind == VENDORED_KIND else (
        request.target or "flat (repo root)"
    )
    if request.kind == RELEASE_KIND:
        return where
    if request.edge_named:
        return where + ", named by the edge that asks for it (--root-owned to link instead)"
    return where + ", root-owned (one install per pin, a link for every edge)"


def _separator_note(world: World, evidence: str) -> str:
    if world.sep_source == "inferred":
        return "inferred: %s" % (evidence or "from tracked file extensions")
    if world.sep_source == "default":
        return "fallback - nothing to measure"
    return world.sep_source


def _act_lines(plan: Plan) -> list[str]:
    if not plan.acts:
        return ["Nothing to do - every declared dependency is already installed.", ""]
    lines = ["PLAN", ""]
    for op in OP_ORDER:
        lines += [_render(act) for act in plan.acts if act.op == op]
    return lines + [""]


def _render(act: Act) -> str:
    body = "  %-9s %-42s" % (act.op, act.entry)
    if act.op in ("link", "copy"):
        return body + " -> " + (act.target or "")
    if act.pin:
        return (body + " @ " + act.pin.short + ("   (%s)" % act.reason if act.reason else "")).rstrip()
    return (body + ("   " + act.reason if act.reason else "")).rstrip()


def _conflict_lines(plan: Plan) -> list[str]:
    lines: list[str] = []
    for conflict in plan.conflicts:
        lines += conflict_prompt(conflict).splitlines() + [""]
    return lines


def conflict_prompt(conflict: Conflict) -> str:
    lines = ["CONFLICT  %s is wanted at two commits" % _remote_name(conflict.remote), ""]
    lines += ["    %s   %s" % (claim.pin.short, _claimant(claim)) for claim in conflict.claims]
    lines += ["", "  " + _ancestry_sentence(conflict), ""]
    for index, option in enumerate(conflict.options, start=1):
        lines += _option_lines(index, option)
    return "\n".join(lines)


def _remote_name(remote: str) -> str:
    return Pin(remote=remote, commit="").name


def _claimant(claim: Claim) -> str:
    return "required by " + claim.dependent if claim.dependent else "required by this project"


def _ancestry_sentence(conflict: Conflict) -> str:
    if conflict.kind == "ambiguous":
        return "several declared entries share this remote; none matches the commit asked for."
    described = {
        "ancestor": "the first commit is an ancestor of the second.",
        "descendant": "the second commit is an ancestor of the first.",
        "diverged": "the two commits have diverged - neither contains the other.",
    }
    return described.get(conflict.ancestry, "the relationship between the commits is unknown.")


def _option_lines(index: int, option: Option) -> list[str]:
    lines = ["  %d) %-16s %s" % (index, option.id.capitalize(), option.label)]
    lines += ["       -> %s @ %s" % (entry, pin.short) for pin, entry in option.placements]
    if option.risk:
        lines.append("       !  " + option.risk)
    return lines


def plan_json(world: World, plan: Plan, request: Request) -> str:
    document = {
        "version": 1,
        "repo": world.repo,
        "separator": world.sep,
        "separator_source": world.sep_source,
        "kind": request.kind,
        "layout": VENDOR_DIR if request.kind == VENDORED_KIND else (request.target or "flat"),
        "blockers": list(plan.blockers),
        "warnings": list(plan.warnings),
        "acts": [_act_json(act) for act in plan.acts],
        "conflicts": [_conflict_json(conflict) for conflict in plan.conflicts],
    }
    return json.dumps(document, indent=2, sort_keys=False)


def _act_json(act: Act) -> dict[str, object]:
    document: dict[str, object] = {"op": act.op, "entry": act.entry}
    if act.pin:
        document["pin"] = _pin_json(act.pin)
    for key, value in (
        ("dest", act.dest),
        ("target", act.target),
        ("section", act.section),
        ("reason", act.reason),
    ):
        if value:
            document[key] = value
    return document


def _pin_json(pin: Pin) -> dict[str, str]:
    return {"remote": pin.remote, "branch": pin.branch, "commit": pin.commit}


def _conflict_json(conflict: Conflict) -> dict[str, object]:
    return {
        "remote": conflict.remote,
        "kind": conflict.kind,
        "ancestry": conflict.ancestry,
        "involves_root": conflict.involves_root,
        "claims": [
            {"dependent": claim.dependent, "commit": claim.pin.commit} for claim in conflict.claims
        ],
        "options": [
            {"id": option.id, "entries": list(option.entries), "risk": option.risk}
            for option in conflict.options
        ],
    }


def findings_json(findings: Sequence[Finding]) -> str:
    return json.dumps(
        {
            "version": 1,
            "findings": [
                {
                    "level": finding.level,
                    "code": finding.code,
                    "where": finding.where,
                    "message": finding.message,
                }
                for finding in findings
            ],
        },
        indent=2,
    )


# --------------------------------------------------------------------------- #
# 14. Prompting - always /dev/tty                                              #
# --------------------------------------------------------------------------- #


class tty:
    """The bootstrap pipes a `.gitrepo` into our stdin, so a prompt that reads
    stdin would hang or eat the manifest. Ask the terminal directly."""

    @staticmethod
    def available() -> bool:
        return os.path.exists(TERMINAL) and sys.stdin.isatty()

    @staticmethod
    def ask(
        question: str,
        answers: Sequence[str],
        default: Optional[str] = None,
        path: str = TERMINAL,
    ) -> str:
        """Two handles, not one opened "r+": a terminal is not seekable, and
        Python's buffered random-access mode refuses to wrap anything that
        isn't. `path` is a parameter so this can be exercised against a real
        pty instead of only in someone's terminal."""
        with open(path, "r") as reading, open(path, "w") as writing:
            return tty._answer(question, answers, default, reading, writing)

    @staticmethod
    def _answer(
        question: str,
        answers: Sequence[str],
        default: Optional[str],
        reading: TextIO,
        writing: TextIO,
    ) -> str:
        for _ in range(MAX_PROMPTS):
            writing.write(question)
            writing.flush()
            line = reading.readline()
            if not line:
                return tty._no_answer(default)
            given = line.strip().lower()
            if not given and default:
                return default
            if given in answers:
                return given
        return tty._no_answer(default)

    @staticmethod
    def _no_answer(default: Optional[str]) -> str:
        """The terminal closed. Taking silence for consent is how an unattended
        run installs something nobody agreed to."""
        if default:
            return default
        raise SuedeError("no usable answer from the terminal; nothing was applied")


def choose_resolutions(conflicts: Sequence[Conflict], out: TextIO) -> dict[str, int]:
    """Nothing is preselected: silent version selection is not a feature."""
    choices: dict[str, int] = {}
    for conflict in conflicts:
        out.write(conflict_prompt(conflict) + "\n")
        numbers = [str(index) for index in range(1, len(conflict.options) + 1)]
        choices[conflict.remote] = int(tty.ask("  [1-%s] " % numbers[-1], numbers)) - 1
    return choices


def confirm() -> bool:
    if not tty.available():
        return False
    return tty.ask("Proceed? [Y/n] ", ("y", "n"), default="y") == "y"


# --------------------------------------------------------------------------- #
# 15. apply() - journal and rollback                                           #
# --------------------------------------------------------------------------- #


class Journal:
    """`git checkout -- .` would undo unrelated work, so remember exactly what
    we created and exactly what we overwrote, and undo only that."""

    def __init__(self, root: str):
        self.root: str = root
        self._created: list[str] = []
        self._original: dict[str, Optional[str]] = {}

    def creating(self, path: str) -> str:
        self._created.append(path)
        return os.path.join(self.root, path)

    def modifying(self, path: str) -> str:
        absolute = os.path.join(self.root, path)
        if path not in self._original:
            self._original[path] = _read_text(absolute)
        return absolute

    def rollback(self) -> None:
        for path in reversed(self._created):
            _remove(os.path.join(self.root, path))
        for path, content in self._original.items():
            absolute = os.path.join(self.root, path)
            if content is None:
                _remove(absolute)
            else:
                _write_text(absolute, content)


def _read_text(path: str) -> Optional[str]:
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def _write_text(path: str, content: str) -> None:
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(content)


def _remove(path: str) -> None:
    if os.path.islink(path) or os.path.isfile(path):
        os.remove(path)
    elif os.path.isdir(path):
        shutil.rmtree(path, ignore_errors=True)


def apply(world: World, plan: Plan, staged: Staged) -> tuple[str, ...]:
    """Acts arrive in OP_ORDER, which is also the only safe order to run them:
    real installs, then the entries pointing at them, then the manifest."""
    journal = Journal(world.root)
    touched: list[str] = []
    try:
        for act in plan.acts:
            touched += APPLIERS.get(act.op, _apply_nothing)(world, act, staged, journal)
    except BaseException:
        journal.rollback()
        raise
    git.add(touched, cwd=world.root)
    return tuple(touched)


# Every applier takes the same four arguments so APPLIERS can dispatch on op
# alone; the ones an op has no use for are named with a leading underscore.
def _apply_nothing(_world: World, _act: Act, _staged: Staged, _journal: Journal) -> list[str]:
    return []


def _apply_install(world: World, act: Act, staged: Staged, journal: Journal) -> list[str]:
    destination = journal.creating(act.required_dest)
    shutil.copytree(
        staged.trees[act.required_pin],
        destination,
        ignore=shutil.ignore_patterns(".git"),
        symlinks=True,
    )
    gitrepo.write(os.path.join(destination, GITREPO), act.required_pin, parent=world.head)
    return [act.required_dest]


def _apply_link(world: World, act: Act, _staged: Staged, journal: Journal) -> list[str]:
    path = journal.creating(act.entry)
    os.makedirs(os.path.dirname(path) or world.root, exist_ok=True)
    os.symlink(act.required_target, path)
    return [act.entry]


def _apply_copy(world: World, act: Act, _staged: Staged, journal: Journal) -> list[str]:
    path = journal.creating(act.entry)
    shutil.copytree(os.path.join(world.root, act.required_dest), path, symlinks=True)
    return [act.entry]


def _apply_record(world: World, act: Act, _staged: Staged, journal: Journal) -> list[str]:
    path = act.required_dest
    absolute = journal.modifying(path) if os.path.exists(os.path.join(world.root, path)) else journal.creating(path)
    gitrepo.write_manifest_record(absolute, act.required_pin)
    return [path]


def _apply_npm(_world: World, act: Act, _staged: Staged, journal: Journal) -> list[str]:
    """Never touches package-lock.json - that is `npm install`'s job."""
    package, wanted = act.entry.rsplit("@", 1)
    file = act.dest or PACKAGE_JSON
    path = journal.modifying(file)
    document = json.loads(_read_text(path) or "{}")
    document.setdefault(act.section or NPM_SECTION, {})[package] = wanted
    _write_text(path, json.dumps(document, indent=2) + "\n")
    return [file]


def _apply_pip(_world: World, act: Act, _staged: Staged, journal: Journal) -> list[str]:
    """Appends. The order of a requirements file is meaningful to whoever wrote
    it, and rewriting one to be tidy would lose the comments that explain it."""
    file = act.dest or REQUIREMENTS
    path = journal.modifying(file)
    existing = _read_text(path) or ""
    if existing and not existing.endswith("\n"):
        existing += "\n"
    _write_text(path, existing + act.entry + "\n")
    return [file]


APPLIERS = {
    "install": _apply_install,
    "link": _apply_link,
    "copy": _apply_copy,
    "record": _apply_record,
    "npm": _apply_npm,
    "pip": _apply_pip,
}


# --------------------------------------------------------------------------- #
# 16. check() - pure                                                           #
# --------------------------------------------------------------------------- #

LEVEL_ORDER = ("FAIL", "WARN", "INFO")


def check(world: World) -> tuple[Finding, ...]:
    findings = list(_edge_findings(world)) + list(_entry_findings(world))
    return tuple(sorted(findings, key=lambda f: (LEVEL_ORDER.index(f.level), f.where, f.code)))


def _edge_findings(world: World) -> Iterable[Finding]:
    """Every dependency's manifest asks for siblings; what a sibling is allowed
    to be depends on what the dependent itself is.

    Only a release dependency carries the declaration invariant - it ships a
    pointer, so the resolution behind that pointer has to be one the consumer
    declared. A development dependency ships nothing and may be satisfied by
    anything on disk. A vendored one ships its own bytes, so its siblings must
    ship too, which means they must live inside release/.
    """
    declared = declarations.backing_paths(world)
    subrepos = declarations.everything(world)
    for edge in world.edges:
        kind = _dependent_kind(world, subrepos, edge)
        path = _sibling_path(edge)
        entry = world.entries.get(path)
        backing = entry.backing if entry else None
        if backing is None:
            yield _missing_edge(edge, path, entry)
        elif kind == RELEASE_KIND and backing not in declared:
            yield _undeclared_edge(path, backing)
        elif kind == VENDORED_KIND and not _inside_release(backing):
            yield _escaping_edge(path, backing)
        else:
            for finding in _pin_notes(world, subrepos, edge, path, backing):
                yield finding


def _dependent_kind(world: World, subrepos: Mapping[str, Install], edge: Edge) -> str:
    dependent = subrepos.get(edge.dependent)
    return declarations.classify(world, dependent) if dependent else RELEASE_KIND


def _inside_release(path: str) -> bool:
    return path == RELEASE_DIR or path.startswith(RELEASE_DIR + "/")


def _sibling_path(edge: Edge) -> str:
    home = os.path.dirname(edge.dependent)
    return os.path.join(home, edge.entry_name) if home else edge.entry_name


def _missing_edge(edge: Edge, path: str, entry: Optional[Entry]) -> Finding:
    return Finding(
        level="FAIL",
        code="missing-edge",
        where=path,
        message="%s expects a sibling named %s and %s. Install %s, or declare your own"
        " resolution at the repo root."
        % (
            os.path.basename(edge.dependent),
            edge.entry_name,
            "it is dangling" if entry else "nothing is there",
            edge.pin.name,
        ),
    )


def _undeclared_edge(path: str, backing: str) -> Finding:
    """The declaration invariant. It compares no remotes and no commits - only
    that a resolution was declared, which is what frees the pin notes below to
    stay informational."""
    return Finding(
        level="FAIL",
        code="undeclared-edge",
        where=path,
        message="%s resolves to %s, which no root entry declares as a release dependency."
        " That is an implicit dependency: give it a root entry so it ships in your manifest."
        % (path, backing),
    )


def _escaping_edge(path: str, backing: str) -> Finding:
    """A vendored dependency's sibling that lives outside release/ resolves
    here and nowhere else: what ships is a link into a directory the consumer
    never receives."""
    return Finding(
        level="FAIL",
        code="escaping-edge",
        where=path,
        message="%s belongs to vendored code but resolves to %s, outside %s/. It ships as a"
        " broken link. Vendor that dependency too, with --vendor." % (path, backing, RELEASE_DIR),
    )


def _pin_notes(
    world: World, subrepos: Mapping[str, Install], edge: Edge, path: str, backing: str
) -> Iterable[Finding]:
    """You took ownership of the resolution. Different commit, different
    remote, or an entirely hand-written implementation are all legitimate."""
    install = subrepos.get(backing)
    if install is None:
        return  # a hand-written implementation has no pin to compare
    resolved = install.pin
    if resolved.remote != edge.pin.remote:
        yield Finding(
            level="INFO",
            code="remote-differs",
            where=path,
            message="%s asks for %s; you resolved it to %s"
            % (os.path.basename(edge.dependent), edge.pin.remote, resolved.remote),
        )
    elif resolved.commit != edge.pin.commit:
        yield Finding(
            level="INFO",
            code="pin-differs",
            where=path,
            message="%s asks for %s; you declare %s"
            % (os.path.basename(edge.dependent), edge.pin.short, resolved.short),
        )


def _entry_findings(world: World) -> Iterable[Finding]:
    for name, entry in sorted(declarations.prefixed_entries(world).items()):
        if declarations.backing_install(world, entry) is None:
            yield _dangling(name, entry)
    for _, names in sorted(_by_lowercase(world).items()):
        if len(names) > 1:
            yield _case_collision(names)


def _dangling(name: str, entry: Entry) -> Finding:
    reason = "does not resolve" if entry.backing is None else "has no .gitrepo"
    return Finding(
        level="WARN",
        code="dangling-entry",
        where=name,
        message="%s is named like a release dependency but %s. The name signals intent,"
        " so this is either an unfinished install or a leftover." % (name, reason),
    )


def _by_lowercase(world: World) -> dict[str, list[str]]:
    grouped: dict[str, list[str]] = {}
    for name in declarations.root_entries(world):
        grouped.setdefault(name.lower(), []).append(name)
    return grouped


def _case_collision(names: Sequence[str]) -> Finding:
    return Finding(
        level="WARN",
        code="case-collision",
        where=sorted(names)[0],
        message="%s differ only by case. They are the same entry on macOS and two"
        " different ones on Linux CI." % " and ".join(sorted(names)),
    )


def worst(findings: Sequence[Finding]) -> str:
    for level in LEVEL_ORDER:
        if any(finding.level == level for finding in findings):
            return level
    return "OK"


def render_findings(findings: Sequence[Finding]) -> str:
    if not findings:
        return "check: no problems found"
    return "\n".join(
        "%-5s %-40s %s" % (finding.level, finding.where, finding.message) for finding in findings
    )


# --------------------------------------------------------------------------- #
# 17. list, extract, remove                                                    #
# --------------------------------------------------------------------------- #


@dataclass(frozen=True)
class Listing:
    entry: str
    kind: str  # "release" | "development" | "vendored"
    path: str
    pin: Optional[Pin]


def listing(world: World) -> tuple[Listing, ...]:
    """Classification is implicit in naming, so a one-command view of what the
    tree currently means is the cheapest fix for 'naming is promotion'."""
    declared = declarations.backing_paths(world)
    rows = [
        Listing(entry=declared.get(path, ""), kind=declarations.classify(world, install),
                path=path, pin=install.pin)
        for path, install in sorted(world.installs.items())
        if not declarations.is_machinery(path)
    ]
    named = _vendored_names(world)
    rows += [Listing(entry=named.get(path, ""), kind=VENDORED_KIND,
                     path=path, pin=install.pin)
             for path, install in sorted(world.vendored.items())
             if not declarations.is_machinery(path)]
    return tuple(rows)


def _vendored_names(world: World) -> dict[str, str]:
    """Install path -> the entry that *is* it. Several entries can name one
    vendored install - its own folder plus every edge link pointing at it - and
    the folder is the one that names it."""
    return {
        install.path: name
        for name, install in declarations.vendored_entries(world).items()
        if os.path.join(VENDOR_DIR, name) == install.path
    }


def render_listing(rows: Sequence[Listing]) -> str:
    if not rows:
        return "no suede dependencies found"
    header = "%-12s %-38s %-38s %s" % ("KIND", "ENTRY", "PATH", "PIN")
    body = [
        "%-12s %-38s %-38s %s"
        % (row.kind, row.entry or "-", row.path, row.pin.short if row.pin else "-")
        for row in rows
    ]
    return "\n".join([header] + body)


def listing_json(rows: Sequence[Listing]) -> str:
    return json.dumps(
        {
            "version": 1,
            "dependencies": [
                {
                    "entry": row.entry,
                    "kind": row.kind,
                    "path": row.path,
                    "pin": _pin_json(row.pin) if row.pin else None,
                }
                for row in rows
            ],
        },
        indent=2,
    )


def extract(world: World) -> tuple[str, ...]:
    """Write `release/.suede/.dependencies/` from the classification. A pure
    application has no `release/`, publishes nothing, and so needs none of it."""
    if not world.has_release:
        return ()
    destination = os.path.join(world.root, RELEASE_DIR, MANIFEST_DIR)
    os.makedirs(destination, exist_ok=True)
    written = _write_records(world, destination) + _copy_dependency_files(world, destination)
    return tuple(written) + _prune_stale_records(world, destination)


def _write_records(world: World, destination: str) -> list[str]:
    for name, install in sorted(declarations.by_name(world).items()):
        gitrepo.write_manifest_record(os.path.join(destination, name + GITREPO), install.pin)
    return [name + GITREPO for name in sorted(declarations.by_name(world))]


def _copy_dependency_files(world: World, destination: str) -> list[str]:
    written: list[str] = []
    if world.npm:
        _write_text(
            os.path.join(destination, "package.json"),
            json.dumps({"dependencies": world.npm}, indent=2) + "\n",
        )
        written.append("package.json")
    requirements = os.path.join(world.root, "requirements.txt")
    if os.path.isfile(requirements):
        shutil.copyfile(requirements, os.path.join(destination, "requirements.txt"))
        written.append("requirements.txt")
    return written


def _prune_stale_records(world: World, destination: str) -> tuple[str, ...]:
    expected = {name + GITREPO for name in declarations.by_name(world)}
    removed: list[str] = []
    for filename in sorted(os.listdir(destination)):
        if filename.endswith(GITREPO) and filename not in expected:
            os.remove(os.path.join(destination, filename))
            removed.append(filename)
    return tuple(removed)


@dataclass(frozen=True)
class Divergence:
    entry: str
    path: str
    pin: Pin
    changed: tuple[str, ...]


def divergence_targets(world: World) -> tuple[tuple[str, Install], ...]:
    """Release dependencies only.

    A release dependency must match its pinned commit - that is what makes the
    shipped pointer honest. A vendored dependency exists precisely *because* it
    diverges, and it ships as source, so the rule would be backwards there.
    Development dependencies ship nothing at all.
    """
    return tuple(sorted(declarations.by_name(world).items()))


def diff(world: World, use_cache: bool = True) -> tuple[Divergence, ...]:
    diverged: list[Divergence] = []
    for entry, install in divergence_targets(world):
        pinned = cache.fetch(world.root, install.pin, use_cache)
        changed = _changed_files(pinned, os.path.join(world.root, install.path))
        if changed:
            diverged.append(
                Divergence(entry=entry, path=install.path, pin=install.pin, changed=changed)
            )
    return tuple(diverged)


def _changed_files(pinned: str, local: str) -> tuple[str, ...]:
    """`.gitrepo` is excluded: it is local metadata and always differs."""
    before, after = _digests(pinned), _digests(local)
    return tuple(sorted(set(before) ^ set(after) | {
        path for path in set(before) & set(after) if before[path] != after[path]
    }))


def _digests(directory: str) -> dict[str, str]:
    digests: dict[str, str] = {}
    for parent, subdirs, filenames in os.walk(directory):
        subdirs[:] = sorted(name for name in subdirs if name != ".git")
        for filename in filenames:
            if filename == GITREPO:
                continue
            path = os.path.join(parent, filename)
            digests[os.path.relpath(path, directory)] = _digest(path)
    return digests


def _digest(path: str) -> str:
    if os.path.islink(path):
        return "link:" + os.readlink(path)
    marks = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(65536), b""):
            marks.update(block)
    return marks.hexdigest()


def render_divergence(diverged: Sequence[Divergence]) -> str:
    if not diverged:
        return "diff: every release dependency matches its pinned commit"
    lines: list[str] = []
    for divergence in diverged:
        lines.append(
            "%s has local modifications relative to %s (%s)"
            % (divergence.entry, divergence.pin.short, divergence.pin.remote)
        )
        lines += ["    " + path for path in divergence.changed]
    lines += [
        "",
        "A release dependency ships as a pointer, so the pointer has to be honest.",
        "Either revert these changes, upstream them (.suede/core/upstream), or vendor",
        "the dependency with .suede/core/vendor.sh so the code actually ships.",
    ]
    return "\n".join(lines)


@dataclass(frozen=True)
class Removal:
    entry: str
    removed: tuple[str, ...]
    orphans: tuple[str, ...]


def plan_removal(world: World, entry: str) -> Removal:
    """Flattening creates orphans: remove B and C stays declared, possibly
    unreferenced. Report them - this project may have started importing C
    directly, and no tool here can see imports."""
    install = declarations.by_name(world).get(entry)
    if install is None:
        raise Usage("%s is not a declared release dependency - `suede list` shows what is" % entry)
    removed = [entry, install.path] + _records_for(world, entry)
    return Removal(entry=entry, removed=tuple(removed), orphans=_orphans_without(world, install))


def _records_for(world: World, entry: str) -> list[str]:
    record = os.path.join(RELEASE_DIR, MANIFEST_DIR, entry + GITREPO)
    return [record] if entry in world.records else []


def _orphans_without(world: World, removed: Install) -> tuple[str, ...]:
    still_wanted = {
        edge.pin for edge in world.edges if edge.dependent != removed.path
    }
    return tuple(
        sorted(
            name
            for name, install in declarations.by_name(world).items()
            if install.path != removed.path and install.pin not in still_wanted
        )
    )


# --------------------------------------------------------------------------- #
# 18. CLI                                                                      #
# --------------------------------------------------------------------------- #


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="suede", description=(__doc__ or "").splitlines()[0])
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--repo-name", help="override $repo detection")
    common.add_argument("--separator", help="override $SEP for this project's own entries")
    commands = parser.add_subparsers(dest="command")
    _install_parser(commands, common)
    _audit_parsers(commands, common)
    return parser


# `argparse._SubParsersAction` is what add_subparsers() returns and argparse
# exports no public name for it. Annotations are strings here, so naming it
# costs nothing at runtime.
def _install_parser(
    commands: argparse._SubParsersAction[argparse.ArgumentParser],  # pyright: ignore[reportPrivateUsage]
    common: argparse.ArgumentParser,
) -> None:
    install = commands.add_parser("install", parents=[common], help="install a suede dependency")
    source = install.add_mutually_exclusive_group(required=True)
    source.add_argument("--repo", help="OWNER/REPO, or any git remote URL")
    source.add_argument("--gitrepo", help="path to a .gitrepo file, or - for stdin")
    install.add_argument("--branch", default=RELEASE_BRANCH, help="branch to install from")
    install.add_argument("--at", help="install this commit instead of the branch tip")
    install.add_argument("-r", dest="repo", help=argparse.SUPPRESS)
    # The kind decides everything that distinguishes one install from another:
    # what the entry is named, what may satisfy its edges, and whether the
    # release branch hears about it at all.
    kind = install.add_mutually_exclusive_group()
    kind.add_argument(
        "--dev",
        action="store_true",
        help="install as a development dependency: unprefixed, not recorded in your manifest,"
        " and its own dependencies are not doubled as yours",
    )
    kind.add_argument(
        "--vendor",
        action="store_true",
        help="install as a vendored release dependency: source and all inside %s/, with its"
        " own dependencies vendored beside it" % RELEASE_DIR,
    )
    install.add_argument("--name", help="override the entry name")
    install.add_argument(
        "--root-owned",
        action="store_true",
        help="install each dependency under its own name and give every edge a link, the way"
        " release dependencies must be. --dev and --vendor otherwise name a transitive install"
        " after the edge that asks for it, which needs no link (release installs are always"
        " root-owned, so the flag is a no-op there)",
    )
    install.add_argument(
        "--commit-suffix", action="store_true", help="pin the entry name to the commit too"
    )
    install.add_argument("--target", default="", help="relocate the real install (at your own risk)")
    install.add_argument("--link-mode", choices=("symlink", "copy"), default="symlink")
    install.add_argument("--on-conflict", choices=("ask", "coexist", "unify-newest", "defer"))
    install.add_argument("--no-npm", action="store_true", help="do not merge npm dependencies")
    install.add_argument(
        "--no-python", action="store_true", help="do not merge requirements.txt dependencies"
    )
    install.add_argument(
        ALLOW_CONFLICTS_FLAG,
        action="store_true",
        help="install even where a dependency's npm or python versions disagree with yours,"
        " keeping your own declarations",
    )
    install.add_argument("--no-cache", action="store_true", help="ignore .git/suede-cache")
    install.add_argument("--dry-run", action="store_true", help="plan and announce, change nothing")
    install.add_argument("--plan-json", action="store_true", help="emit the plan as JSON")
    install.add_argument("--yes", action="store_true", help="accept the plan without asking")
    install.add_argument("--commit", action="store_true", help="commit the result")


def _audit_parsers(
    commands: argparse._SubParsersAction[argparse.ArgumentParser],  # pyright: ignore[reportPrivateUsage]
    common: argparse.ArgumentParser,
) -> None:
    check_command = commands.add_parser("check", parents=[common], help="audit the tree")
    check_command.add_argument("--plan-json", action="store_true")
    list_command = commands.add_parser("list", parents=[common], help="show every dependency")
    list_command.add_argument("--json", action="store_true")
    commands.add_parser("extract", parents=[common], help="write release/.suede/.dependencies/")
    diff_command = commands.add_parser(
        "diff", parents=[common], help="show release dependencies that differ from their pin"
    )
    diff_command.add_argument("--no-cache", action="store_true")
    remove = commands.add_parser("remove", parents=[common], help="drop a declared entry")
    remove.add_argument("entry")
    remove.add_argument("--yes", action="store_true")


def _open_world(args: argparse.Namespace) -> tuple[World, tuple[str, ...]]:
    root = git.toplevel()
    os.chdir(root)
    repo, notes = context.repo_name(root, args.repo_name)
    separator, source = context.separator(root, repo, args.separator)
    return scan(root, repo, separator, source), notes


def remote_from(repo: str) -> str:
    """Any git remote works: `git clone` takes the URL verbatim and a
    dependency's name is just its basename. OWNER/REPO is a GitHub shorthand,
    not a restriction."""
    if "://" in repo or repo.startswith("git@") or os.path.isdir(repo):
        return repo
    if repo.count("/") == 1 and all(part for part in repo.split("/")):
        return "https://github.com/" + repo
    raise Usage("--repo wants OWNER/REPO or a git remote URL (got %s)" % repo)


def _requested_pin(args: argparse.Namespace) -> Pin:
    if args.gitrepo:
        return _pin_from_gitrepo(args.gitrepo)
    remote = remote_from(args.repo)
    commit = args.at or git.resolve_branch(remote, args.branch)
    return Pin(remote=remote, commit=commit, branch=args.branch)


def _pin_from_gitrepo(source: str) -> Pin:
    path = source if source != "-" else _stdin_to_temporary_file()
    pin = gitrepo.read(path)
    if pin is None:
        raise Usage("%s is not a readable .gitrepo (needs `remote` and `commit`)" % source)
    return pin


def _stdin_to_temporary_file() -> str:
    handle = tempfile.NamedTemporaryFile("w", suffix=".gitrepo", delete=False, encoding="utf-8")
    handle.write(sys.stdin.read())
    handle.close()
    return handle.name


def _kind(args: argparse.Namespace) -> str:
    if args.vendor:
        return VENDORED_KIND
    return DEVELOPMENT_KIND if args.dev else RELEASE_KIND


def _request(args: argparse.Namespace) -> Request:
    kind = _kind(args)
    if kind == VENDORED_KIND and args.target:
        raise Usage(
            "--vendor and --target disagree about where the bytes go: vendored code has to"
            " live inside %s/ to ship at all." % RELEASE_DIR
        )
    return Request(
        pins=(_requested_pin(args),),
        kind=kind,
        name=args.name,
        target=args.target.strip("/"),
        link_mode=args.link_mode,
        commit_suffix=args.commit_suffix,
        root_owned=args.root_owned,
    )


def _policy(args: argparse.Namespace) -> Policy:
    fallback = "ask" if tty.available() else "defer"
    return Policy(
        on_conflict=args.on_conflict or fallback,
        npm=not args.no_npm,
        python=not args.no_python,
        allow_package_conflicts=args.allow_conflicting_packages,
    )


def install_command(args: argparse.Namespace) -> int:
    world, notes = _open_world(args)
    request = _request(args)
    policy = _policy(args)
    staged = stage(world, request.pins, use_cache=not args.no_cache, kind=request.kind)
    proposal = _propose(world, request, policy, staged)
    if args.plan_json:
        print(plan_json(world, proposal, request))
        return _plan_exit_code(proposal)
    _report(notes, announce(world, proposal, request, context.evidence(world.root, world.sep, world.sep_source)))
    if proposal.blockers or proposal.conflicts or args.dry_run or not proposal.mutates:
        return _plan_exit_code(proposal)
    if not (args.yes or confirm()):
        return Exit.UNRESOLVED
    return _carry_out(world, request, proposal, staged, args)


def _propose(world: World, request: Request, policy: Policy, staged: Staged) -> Plan:
    proposal = plan(world, request, policy, staged.manifests, staged.ancestry)
    if not (proposal.conflicts and policy.on_conflict == "ask" and tty.available()):
        return proposal
    chosen = replace(policy, choices=choose_resolutions(proposal.conflicts, sys.stdout))
    return plan(world, request, chosen, staged.manifests, staged.ancestry)


def _plan_exit_code(proposal: Plan) -> int:
    if proposal.blockers:
        return Exit.PRECONDITION
    return Exit.UNRESOLVED if proposal.conflicts else Exit.OK


def _report(notes: Sequence[str], text: str) -> None:
    for note in notes:
        sys.stderr.write("warning: %s\n" % note)
    print(text)


def _carry_out(
    world: World, request: Request, proposal: Plan, staged: Staged, args: argparse.Namespace
) -> int:
    apply(world, proposal, staged)
    if request.kind == RELEASE_KIND:
        # The separator names this project's own release entries and nothing
        # else, so only a run that used it has learned anything worth keeping.
        _persist_separator(world)
    if args.commit:
        print("committed %s" % git.commit(_commit_message(proposal), cwd=world.root))
    return _verify(world)


def _persist_separator(world: World) -> None:
    """Written so later installs resolve the same separator without measuring."""
    path = os.path.join(world.root, SEPARATOR_FILE)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    _write_text(path, world.sep + "\n")
    git.add([os.path.relpath(path, world.root)], cwd=world.root)


def _commit_message(proposal: Plan) -> str:
    installed = [act.entry for act in proposal.acts if act.op == "install"]
    return "Add suede dependencies: " + ", ".join(installed) if installed else "Update suede dependencies"


def _verify(world: World) -> int:
    """A failure here is a bug in apply, not in the tree."""
    findings = check(scan(world.root, world.repo, world.sep, world.sep_source))
    failures = [finding for finding in findings if finding.level == "FAIL"]
    if failures:
        sys.stderr.write("install finished but check failed - this is a bug in suede:\n")
        sys.stderr.write(render_findings(failures) + "\n")
        return Exit.CHECK_FAILED
    return Exit.OK


def diff_command(args: argparse.Namespace) -> int:
    world, notes = _open_world(args)
    diverged = diff(world, use_cache=not args.no_cache)
    _report(notes, render_divergence(diverged))
    return Exit.CHECK_FAILED if diverged else Exit.OK


def check_command(args: argparse.Namespace) -> int:
    world, notes = _open_world(args)
    findings = check(world)
    _report(notes, findings_json(findings) if args.plan_json else render_findings(findings))
    return Exit.CHECK_FAILED if worst(findings) == "FAIL" else Exit.OK


def list_command(args: argparse.Namespace) -> int:
    world, notes = _open_world(args)
    rows = listing(world)
    _report(notes, listing_json(rows) if args.json else render_listing(rows))
    return Exit.OK


def extract_command(args: argparse.Namespace) -> int:
    world, _ = _open_world(args)
    if not world.has_release:
        print("no release/ directory - nothing to extract")
        return Exit.OK
    written = extract(world)
    print("extract: wrote %d entries into %s" % (len(written), os.path.join(RELEASE_DIR, MANIFEST_DIR)))
    return Exit.OK


def remove_command(args: argparse.Namespace) -> int:
    world, _ = _open_world(args)
    removal = plan_removal(world, args.entry)
    print(_render_removal(removal))
    if not (args.yes or confirm()):
        return Exit.UNRESOLVED
    for path in removal.removed:
        _remove(os.path.join(world.root, path))
    git.add(list(removal.removed), cwd=world.root)
    return Exit.OK


def _render_removal(removal: Removal) -> str:
    lines = ["remove %s" % removal.entry] + ["  delete   %s" % path for path in removal.removed]
    if removal.orphans:
        lines += [
            "",
            "  These stay declared and are now referenced by nothing. They are not deleted:",
            "  you may have started importing them directly, and no tool here can see imports.",
        ] + ["    %s" % orphan for orphan in removal.orphans]
    return "\n".join(lines)


COMMANDS = {
    "install": install_command,
    "check": check_command,
    "diff": diff_command,
    "list": list_command,
    "extract": extract_command,
    "remove": remove_command,
}


def bound_the_network() -> None:
    os.environ.setdefault("GIT_TERMINAL_PROMPT", "0")
    os.environ.setdefault("GIT_SSH_COMMAND", SSH_ATTEMPT)


def main(argv: Sequence[str]) -> int:
    bound_the_network()
    parser = _parser()
    args = parser.parse_args(argv)
    if not args.command:
        parser.print_help()
        return Exit.USAGE
    try:
        return COMMANDS[args.command](args)
    except SuedeError as failure:
        sys.stderr.write("suede: %s\n" % failure)
        return failure.code


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
