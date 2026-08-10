"""Resolving `$repo` and `$SEP`.

Both read the working tree, so they are exercised against real repositories.
The separator is the project's own choice about its own entries, and the
precedence is what makes that choice stick.
"""

import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "fixtures"))
sys.path.insert(0, os.path.join(HERE, "..", "..", "scripts"))

import make_graph  # noqa: E402
import suede  # noqa: E402


class Repository(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.mkdtemp(prefix="suede-context-")
        self.addCleanup(shutil.rmtree, self.directory, True)
        self.root = os.path.join(self.directory, "app")
        make_graph.git("init", "--quiet", "--initial-branch=main", self.root)

    def add(self, *paths):
        for path in paths:
            make_graph.write(os.path.join(self.root, path), "x\n")
        make_graph.git("add", "-A", cwd=self.root)

    def folder(self, name):
        os.makedirs(os.path.join(self.root, name), exist_ok=True)

    def separator(self, repo="app", override=None):
        return suede.context.separator(self.root, repo, override)


class SeparatorPrecedence(Repository):
    def test_the_flag_beats_everything(self):
        self.add("main.py")
        self.declare("__")

        self.assertEqual(self.separator(override="::"), ("::", "flag"))

    def test_the_declared_file_beats_the_tree(self):
        self.add("main.ts")

        self.declare("__")

        self.assertEqual(self.separator(), ("__", "file"))

    def test_existing_entries_beat_inference(self):
        self.add("main.ts")
        self.folder("app__one")
        self.folder("app__two")

        self.assertEqual(self.separator(), ("__", "entries"))

    def test_inference_reads_tracked_files_only(self):
        self.add("main.py", "helper.py")
        make_graph.write(os.path.join(self.root, "ignored.ts"), "x\n")

        self.assertEqual(self.separator(), ("__", "inferred"))

    def test_a_dot_language_infers_a_dot(self):
        self.add("main.ts", "component.svelte")

        self.assertEqual(self.separator(), (".", "inferred"))

    def test_a_tie_falls_back_to_the_default(self):
        self.add("main.ts", "main.py")

        self.assertEqual(self.separator(), (".", "default"))

    def test_an_empty_repository_says_it_was_a_fallback_not_a_measurement(self):
        self.assertEqual(self.separator(), (".", "default"))

    def declare(self, separator):
        make_graph.write(os.path.join(self.root, suede.SEPARATOR_FILE), separator + "\n")


class RepoName(Repository):
    def test_the_directory_name_is_used_when_there_is_no_origin(self):
        self.assertEqual(suede.context.repo_name(self.root, None), ("app", ()))

    def test_the_flag_wins(self):
        self.assertEqual(suede.context.repo_name(self.root, "chosen"), ("chosen", ()))

    def test_origin_wins_over_the_directory_but_says_so(self):
        make_graph.git("remote", "add", "origin", "https://example.test/acme/renamed.git", cwd=self.root)

        name, notes = suede.context.repo_name(self.root, None)

        self.assertEqual(name, "renamed")
        self.assertEqual(len(notes), 1)
        self.assertIn("renamed", notes[0])

    def test_a_name_containing_dots_is_matched_verbatim(self):
        make_graph.git("remote", "add", "origin", "https://example.test/acme/my.app.git", cwd=self.root)

        name, _ = suede.context.repo_name(self.root, None)
        world = suede.scan(self.root, name, ".", "flag")

        self.assertEqual(name, "my.app")
        self.assertTrue(suede.declarations.is_prefixed(world, "my.app.dep"))
        self.assertFalse(suede.declarations.is_prefixed(world, "my.other"))


class Prefixing(Repository):
    def test_a_bare_prefix_without_a_separator_is_not_a_release_dependency(self):
        world = suede.scan(self.root, "suede", ".", "flag")

        self.assertFalse(suede.declarations.is_prefixed(world, "suede-extras"))
        self.assertTrue(suede.declarations.is_prefixed(world, "suede.extras"))

    def test_a_project_separator_outside_the_legal_pair_still_classifies(self):
        world = suede.scan(self.root, "app", "::", "flag")

        self.assertTrue(suede.declarations.is_prefixed(world, "app::dep"))
        self.assertTrue(suede.declarations.is_prefixed(world, "app.dep"))


if __name__ == "__main__":
    unittest.main()
