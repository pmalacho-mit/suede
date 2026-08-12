"""The handoff from an install to git-subrepo.

`suede install` writes each `.gitrepo` by hand rather than going through
`git subrepo clone`. What makes that honest is that git-subrepo accepts the
result, so these run the real thing against a really installed tree.

This is the one failure mode nothing else in the suite would notice: the
assertions elsewhere are about the tree suede writes, and every one of them
would stay green if git-subrepo changed its assumptions about that tree.
"""

import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "fixtures"))
sys.path.insert(0, os.path.join(HERE, "..", "..", "scripts"))

import make_graph  # noqa: E402
import suede  # noqa: E402
from test_install import Fixture  # noqa: E402

PUBLISHED_LATER = "export const dockview = 2;\n"
EDITED_LOCALLY = "export const dockview = 3;\n"


def git_subrepo_is_installed():
    try:
        subprocess.check_call(
            ["git", "subrepo", "--version"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        return False
    return True


@unittest.skipUnless(git_subrepo_is_installed(), "git-subrepo is not installed")
class Handoff(Fixture):
    """`sweater` is installed rather than `dockview` alone, so the tree the
    pull runs against is the interesting one: a root-level install with a
    symlinked sibling pointing at it."""

    graph = {"dockview": {}, "sweater": {"sweater.dockview": ("dockview", "HEAD")}}

    def setUp(self):
        super(Handoff, self).setUp()
        self.assertEqual(self.install("sweater", "--commit"), suede.Exit.OK)

    def subrepo(self, *argv):
        result = subprocess.run(
            ("git", "subrepo") + argv,
            cwd=self.consumer,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            universal_newlines=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        return result.stdout

    def contents(self, *parts):
        with open(self.path(*parts), encoding="utf-8") as handle:
            return handle.read()

    def released(self, node):
        return make_graph.git(
            "--git-dir=" + self.nodes[node].remote, "cat-file", "-p", "release:index.ts"
        )

    def publish_one_more_commit(self, node):
        return make_graph.advance(self.directory, self.nodes[node], PUBLISHED_LATER)

    def test_a_pull_brings_down_what_was_published_after_the_install(self):
        self.publish_one_more_commit("dockview")

        self.subrepo("pull", "app.dockview")

        self.assertEqual(self.contents("app.dockview", "index.ts"), PUBLISHED_LATER)

    def test_a_pull_records_the_commit_it_landed_on(self):
        published = self.publish_one_more_commit("dockview")

        self.subrepo("pull", "app.dockview")

        self.assertEqual(self.pin_of("app.dockview", ".gitrepo").commit, published)

    def test_a_pull_leaves_nothing_uncommitted_behind(self):
        self.publish_one_more_commit("dockview")

        self.subrepo("pull", "app.dockview")

        self.assertEqual(self.status(), "")

    def test_the_symlinked_sibling_is_inert_across_a_pull(self):
        self.publish_one_more_commit("dockview")

        self.subrepo("pull", "app.dockview")

        self.assertTrue(os.path.islink(self.path("sweater.dockview")))
        self.assertEqual(self.contents("sweater.dockview", "index.ts"), PUBLISHED_LATER)

    def test_the_dependent_that_carries_a_manifest_pulls_too(self):
        self.publish_one_more_commit("sweater")

        self.subrepo("pull", "app.sweater")

        self.assertEqual(self.contents("app.sweater", "index.ts"), PUBLISHED_LATER)

    def test_a_local_edit_pushes_back_to_the_release_branch(self):
        make_graph.write(self.path("app.dockview", "index.ts"), EDITED_LOCALLY)
        make_graph.git("commit", "-aqm", "edit the dependency", cwd=self.consumer)

        self.subrepo("push", "app.dockview")

        self.assertEqual(self.released("dockview"), EDITED_LOCALLY.strip())


if __name__ == "__main__":
    unittest.main()
