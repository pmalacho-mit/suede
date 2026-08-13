"""End-to-end installs against real local repositories.

These cover what a literal `World` cannot: that the tree suede writes is the
tree it planned. Anything provable without git belongs in `.tests/unit/`.
"""

import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "fixtures"))
sys.path.insert(0, os.path.join(HERE, "..", "..", "scripts"))

import make_graph  # noqa: E402
import suede  # noqa: E402

CHAIN = {
    "dockview": {},
    "sweater": {"sweater.dockview": ("dockview", "HEAD")},
    "renderer": {"renderer.dockview": ("dockview", "HEAD~3")},
    "bundle": {"bundle.renderer": ("renderer", "HEAD"), "bundle.sweater": ("sweater", "HEAD")},
}


class Fixture(unittest.TestCase):
    graph = CHAIN
    publishes = {}
    release = False

    def setUp(self):
        self.directory = tempfile.mkdtemp(prefix="suede-test-")
        self.addCleanup(shutil.rmtree, self.directory, True)
        self.addCleanup(os.chdir, os.getcwd())
        self.nodes = make_graph.build(self.graph, self.directory, self.publishes)
        self.consumer = make_graph.consumer(self.directory, release=self.release)
        os.chdir(self.consumer)

    def suede(self, *argv):
        return suede.main(list(argv))

    def install(self, node, *extra):
        return self.suede("install", "--repo", self.nodes[node].remote, "--yes", *extra)

    def path(self, *parts):
        return os.path.join(self.consumer, *parts)

    def exists(self, *parts):
        return os.path.lexists(self.path(*parts))

    def status(self):
        return make_graph.git("status", "--porcelain", cwd=self.consumer)

    def pin_of(self, *parts):
        return suede.gitrepo.read(self.path(*parts))


class SingleInstall(Fixture):
    def test_installs_the_bytes_and_writes_a_live_gitrepo(self):
        self.assertEqual(self.install("dockview"), suede.Exit.OK)

        self.assertTrue(self.exists("app.dockview", "index.ts"))
        self.assertEqual(self.pin_of("app.dockview", ".gitrepo").commit, self.nodes["dockview"].commits[-1])

    def test_parent_is_the_commit_the_install_will_descend_from(self):
        head = make_graph.git("rev-parse", "HEAD", cwd=self.consumer)

        self.install("dockview")

        self.assertEqual(suede.gitrepo.parent(self.path("app.dockview", ".gitrepo")), head)

    def test_the_install_is_staged_but_not_committed(self):
        before = make_graph.git("rev-parse", "HEAD", cwd=self.consumer)

        self.install("dockview")

        self.assertEqual(make_graph.git("rev-parse", "HEAD", cwd=self.consumer), before)
        self.assertIn("A  app.dockview/index.ts", self.status())

    def test_commit_produces_exactly_one_commit(self):
        before = make_graph.git("rev-list", "--count", "HEAD", cwd=self.consumer)

        self.assertEqual(self.install("sweater", "--commit"), suede.Exit.OK)

        after = make_graph.git("rev-list", "--count", "HEAD", cwd=self.consumer)
        self.assertEqual(int(after) - int(before), 1)
        self.assertEqual(self.status(), "")


class TransitiveInstall(Fixture):
    def test_the_root_owns_the_bytes_and_the_dependent_gets_a_link(self):
        self.assertEqual(self.install("sweater"), suede.Exit.OK)

        self.assertTrue(os.path.isdir(self.path("app.dockview")))
        self.assertTrue(os.path.islink(self.path("sweater.dockview")))
        self.assertEqual(os.readlink(self.path("sweater.dockview")), "./app.dockview")

    def test_the_link_resolves_to_the_same_bytes(self):
        self.install("sweater")

        self.assertTrue(self.exists("sweater.dockview", "index.ts"))

    def test_the_installed_tree_passes_check(self):
        self.install("sweater")

        self.assertEqual(self.suede("check"), suede.Exit.OK)

    def test_a_second_run_changes_nothing(self):
        self.install("sweater")
        before = self.status()

        self.assertEqual(self.install("sweater"), suede.Exit.OK)

        self.assertEqual(self.status(), before)


class Conflicts(Fixture):
    """`bundle` pulls in sweater and renderer, which want dockview at two
    different commits - both claims arrive in the same run, with nothing
    declared to settle them."""

    def older(self):
        return self.nodes["dockview"].at("HEAD~3")

    def newer(self):
        return self.nodes["dockview"].commits[-1]

    def test_defers_by_default_and_touches_nothing(self):
        code = self.install("bundle", "--on-conflict", "defer")

        self.assertEqual(code, suede.Exit.UNRESOLVED)
        self.assertEqual(self.status(), "")
        self.assertFalse(self.exists("app.bundle"))

    def test_coexist_installs_both_commits_side_by_side(self):
        code = self.install("bundle", "--on-conflict", "coexist")

        self.assertEqual(code, suede.Exit.OK)
        installed = {
            self.pin_of("app.dockview", ".gitrepo").commit,
            self.pin_of("app.dockview-" + self.newer()[:7], ".gitrepo").commit,
        }
        self.assertEqual(installed, {self.older(), self.newer()})

    def test_coexist_keeps_each_dependent_on_its_own_pin(self):
        self.install("bundle", "--on-conflict", "coexist")

        self.assertEqual(os.readlink(self.path("renderer.dockview")), "./app.dockview")
        self.assertEqual(
            os.readlink(self.path("sweater.dockview")), "./app.dockview-" + self.newer()[:7]
        )

    def test_unify_newest_points_every_edge_at_one_install(self):
        code = self.install("bundle", "--on-conflict", "unify-newest")

        self.assertEqual(code, suede.Exit.OK)
        self.assertEqual(os.readlink(self.path("renderer.dockview")), "./app.dockview")
        self.assertEqual(os.readlink(self.path("sweater.dockview")), "./app.dockview")
        self.assertEqual(self.pin_of("app.dockview", ".gitrepo").commit, self.newer())

    def test_a_declared_entry_settles_a_later_install_without_prompting(self):
        """One root-declared entry for the remote and no exact match is the
        consumer's own resolution: announce it, do not ask again."""
        self.install("sweater")

        code = self.install("renderer")

        self.assertEqual(code, suede.Exit.OK)
        self.assertEqual(os.readlink(self.path("renderer.dockview")), "./app.dockview")
        self.assertEqual(self.pin_of("app.dockview", ".gitrepo").commit, self.newer())


class Rollback(Fixture):
    def test_a_failure_mid_apply_leaves_the_tree_byte_identical(self):
        before = self.status()
        original = shutil.copytree
        calls = []

        def fail_on_the_second_install(*args, **kwargs):
            calls.append(args)
            if len(calls) == 2:
                raise OSError("injected failure")
            return original(*args, **kwargs)

        suede.shutil.copytree = fail_on_the_second_install
        self.addCleanup(setattr, suede.shutil, "copytree", original)

        with self.assertRaises(OSError):
            self.install("sweater")

        self.assertEqual(self.status(), before)
        self.assertFalse(self.exists("app.dockview"))
        self.assertFalse(self.exists("app.sweater"))


class DirtyTree(Fixture):
    def test_installs_and_warns(self):
        make_graph.write(self.path("scratch.ts"), "// uncommitted\n")

        self.assertEqual(self.install("dockview"), suede.Exit.OK)
        self.assertTrue(self.exists("app.dockview"))


class Publishing(Fixture):
    release = True

    def test_the_whole_closure_is_recorded_as_this_project_own_dependency(self):
        self.install("sweater")

        manifest = suede.gitrepo.read_manifest(self.path("release"))
        self.assertEqual(sorted(manifest.edges), ["app.dockview", "app.sweater"])

    def test_a_shipped_record_carries_no_local_bookkeeping(self):
        self.install("sweater")

        record = self.path("release", ".suede", ".dependencies", "app.dockview.gitrepo")
        self.assertEqual(suede.gitrepo.parent(record), "")
        self.assertIsNone(suede.git.config_get(record, "subrepo.cmdver"))

    def test_extract_rewrites_the_manifest_from_the_tree(self):
        self.install("sweater")
        os.remove(self.path("release", ".suede", ".dependencies", "app.dockview.gitrepo"))

        self.assertEqual(self.suede("extract"), suede.Exit.OK)

        manifest = suede.gitrepo.read_manifest(self.path("release"))
        self.assertEqual(sorted(manifest.edges), ["app.dockview", "app.sweater"])

    def test_extract_drops_a_record_whose_entry_is_gone(self):
        self.install("sweater")
        shutil.rmtree(self.path("app.sweater"))

        self.suede("extract")

        manifest = suede.gitrepo.read_manifest(self.path("release"))
        self.assertEqual(sorted(manifest.edges), ["app.dockview"])


class DevelopmentInstall(Fixture):
    """`--dev`: a dependency the release branch never hears about."""

    release = True

    def manifest(self):
        return suede.gitrepo.read_manifest(self.path("release"))

    def test_the_entry_is_unprefixed_and_nothing_is_recorded(self):
        self.assertEqual(self.install("sweater", "--dev"), suede.Exit.OK)

        self.assertTrue(self.exists("sweater", "index.ts"))
        self.assertFalse(self.exists("app.sweater"))
        self.assertEqual(sorted(self.manifest().edges), [])

    def test_its_own_dependencies_are_not_doubled_as_this_projects(self):
        self.install("sweater", "--dev")

        self.assertTrue(self.exists("dockview", "index.ts"))
        self.assertFalse(self.exists("app.dockview"))
        self.assertEqual(os.readlink(self.path("sweater.dockview")), "./dockview")

    def test_a_dependency_already_installed_is_reused_rather_than_copied(self):
        self.install("dockview")

        self.assertEqual(self.install("sweater", "--dev"), suede.Exit.OK)

        self.assertFalse(self.exists("dockview"))
        self.assertEqual(os.readlink(self.path("sweater.dockview")), "./app.dockview")
        self.assertEqual(sorted(self.manifest().edges), ["app.dockview"])

    def test_the_installed_tree_passes_check(self):
        self.install("sweater", "--dev")

        self.assertEqual(self.suede("check"), suede.Exit.OK)

    def test_extract_leaves_it_out_of_the_manifest(self):
        self.install("sweater", "--dev")

        self.assertEqual(self.suede("extract"), suede.Exit.OK)

        self.assertEqual(sorted(self.manifest().edges), [])

    def test_list_calls_it_a_development_dependency(self):
        self.install("sweater", "--dev")

        rows = suede.listing(suede.scan(self.consumer, "app", ".", "flag"))

        self.assertEqual(sorted((row.kind, row.path) for row in rows),
                         [("development", "dockview"), ("development", "sweater")])

    def test_a_second_run_changes_nothing(self):
        self.install("sweater", "--dev")
        before = self.status()

        self.assertEqual(self.install("sweater", "--dev"), suede.Exit.OK)

        self.assertEqual(self.status(), before)


class VendoredInstall(Fixture):
    """`--vendor`: the source ships, so everything it needs ships beside it."""

    release = True

    def test_the_closure_lands_at_the_top_of_release(self):
        self.assertEqual(self.install("sweater", "--vendor"), suede.Exit.OK)

        self.assertTrue(self.exists("release", "sweater", "index.ts"))
        self.assertTrue(self.exists("release", "dockview", "index.ts"))
        self.assertEqual(self.pin_of("release", "sweater", ".gitrepo").commit,
                         self.nodes["sweater"].commits[-1])

    def test_the_edge_is_a_sibling_inside_release_and_nowhere_else(self):
        self.install("sweater", "--vendor")

        self.assertEqual(os.readlink(self.path("release", "sweater.dockview")), "./dockview")
        self.assertTrue(self.exists("release", "sweater.dockview", "index.ts"))
        self.assertFalse(self.exists("sweater.dockview"))

    def test_nothing_reaches_the_root_or_the_manifest(self):
        self.install("sweater", "--vendor")

        self.assertFalse(self.exists("app.sweater"))
        self.assertFalse(self.exists("app.dockview"))
        self.assertEqual(sorted(suede.gitrepo.read_manifest(self.path("release")).edges), [])

    def test_the_installed_tree_passes_check(self):
        self.install("sweater", "--vendor")

        self.assertEqual(self.suede("check"), suede.Exit.OK)

    def test_list_calls_it_vendored(self):
        self.install("sweater", "--vendor")

        rows = suede.listing(suede.scan(self.consumer, "app", ".", "flag"))

        self.assertEqual(sorted((row.kind, row.path) for row in rows),
                         [("vendored", "release/dockview"), ("vendored", "release/sweater")])

    def test_diff_does_not_police_vendored_code(self):
        """Vendoring exists so a dependency *can* diverge from its pin."""
        self.install("sweater", "--vendor")
        make_graph.write(self.path("release", "sweater", "index.ts"), "// patched\n")

        self.assertEqual(self.suede("diff"), suede.Exit.OK)

    def test_a_second_run_changes_nothing(self):
        self.install("sweater", "--vendor")
        before = self.status()

        self.assertEqual(self.install("sweater", "--vendor"), suede.Exit.OK)

        self.assertEqual(self.status(), before)

    def test_a_root_install_of_the_same_commit_is_not_reused(self):
        """Code outside release/ does not ship: reusing it would send consumers
        a link to a directory they never receive."""
        self.install("dockview")

        self.install("sweater", "--vendor")

        self.assertTrue(self.exists("app.dockview", "index.ts"))
        self.assertTrue(self.exists("release", "dockview", "index.ts"))
        self.assertFalse(os.path.islink(self.path("release", "dockview")))

    def test_target_is_refused_because_the_destination_is_not_negotiable(self):
        self.assertEqual(self.install("sweater", "--vendor", "--target", "deps"), suede.Exit.USAGE)


class VendoringWithNothingToShip(Fixture):
    release = False

    def test_is_refused_rather_than_inventing_a_release_folder(self):
        self.assertEqual(self.install("sweater", "--vendor"), suede.Exit.PRECONDITION)

        self.assertFalse(self.exists("release"))
        self.assertEqual(self.status(), "")


class RecordedSpelling(unittest.TestCase):
    """Which URL each kind of `.gitrepo` records.

    A live one drives `git subrepo pull` and `push` on the installed folder, so
    it records SSH — the only spelling that can still authenticate a write. A
    published one is resolved by consumers and by CI runners holding no key of
    ours, so it records HTTPS. The graph fixtures use local paths, which have a
    single spelling, so this is the only place the split is observable.
    """

    HTTPS = "https://github.com/pmalacho-mit/programmatic-docker-suede"
    SSH = "git@github.com:pmalacho-mit/programmatic-docker-suede.git"

    def setUp(self):
        self.directory = tempfile.mkdtemp(prefix="suede-test-")
        self.addCleanup(shutil.rmtree, self.directory, True)
        self.pin = suede.Pin(remote=self.HTTPS, commit="a" * 40)

    def recorded(self, write, name, pin=None):
        path = os.path.join(self.directory, name)
        write(path, pin or self.pin)
        return suede.git.config_get(path, "subrepo.remote")

    def test_a_live_gitrepo_records_ssh(self):
        self.assertEqual(self.recorded(suede.gitrepo.write, "live"), self.SSH)

    def test_a_published_record_keeps_https(self):
        self.assertEqual(self.recorded(suede.gitrepo.write_manifest_record, "published"), self.HTTPS)

    def test_the_spelling_it_was_given_does_not_decide_what_is_written(self):
        over_ssh = suede.Pin(remote=self.SSH, commit="a" * 40)

        self.assertEqual(self.recorded(suede.gitrepo.write, "live", over_ssh), self.SSH)
        self.assertEqual(
            self.recorded(suede.gitrepo.write_manifest_record, "published", over_ssh), self.HTTPS
        )

    def test_both_read_back_as_the_same_pin(self):
        live = os.path.join(self.directory, "live")
        published = os.path.join(self.directory, "published")
        suede.gitrepo.write(live, self.pin)
        suede.gitrepo.write_manifest_record(published, self.pin)

        self.assertEqual(suede.gitrepo.read(live), suede.gitrepo.read(published))

    def test_a_remote_with_one_spelling_is_written_verbatim_either_way(self):
        """Local paths and addresses carrying a port cannot be rewritten, and
        must not be: the fixtures, a self-hosted forge and the Gitea harness all
        depend on the URL surviving untouched."""
        local = suede.Pin(remote=os.path.join(self.directory, "dep.git"), commit="a" * 40)

        self.assertEqual(self.recorded(suede.gitrepo.write, "live", local), local.remote)
        self.assertEqual(
            self.recorded(suede.gitrepo.write_manifest_record, "published", local), local.remote
        )


class Vendoring(Fixture):
    release = True

    def test_the_release_folders_own_pointer_is_not_a_vendored_dependency(self):
        """release/.gitrepo points at the branch release/ is published to."""
        make_graph.write(self.path("release", ".gitrepo"), "[subrepo]\n\tremote = x\n\tcommit = y\n")

        self.assertEqual(dict(suede.scan(self.consumer, "app", ".", "flag").vendored), {})

    def test_a_subrepo_inside_release_is_vendored(self):
        make_graph.write(
            self.path("release", "widget", ".gitrepo"),
            "[subrepo]\n\tremote = x\n\tcommit = y\n",
        )

        world = suede.scan(self.consumer, "app", ".", "flag")
        self.assertEqual(sorted(world.vendored), ["release/widget"])
        self.assertEqual(world.vendored["release/widget"].pin.commit, "y")
        self.assertEqual(world.installs, {})


class UnbornHead(unittest.TestCase):
    def test_refuses_to_install_before_the_first_commit(self):
        directory = tempfile.mkdtemp(prefix="suede-test-")
        self.addCleanup(shutil.rmtree, directory, True)
        self.addCleanup(os.chdir, os.getcwd())
        nodes = make_graph.build({"dockview": {}}, directory)
        empty = os.path.join(directory, "empty")
        make_graph.git("init", "--quiet", empty)
        os.chdir(empty)

        code = suede.main(["install", "--repo", nodes["dockview"].remote, "--yes"])

        self.assertEqual(code, suede.Exit.PRECONDITION)
        self.assertFalse(os.path.exists(os.path.join(empty, "empty.dockview")))


class Listing(Fixture):
    def test_names_each_dependency_and_its_classification(self):
        self.install("sweater")

        rows = suede.listing(self._world())

        self.assertEqual(
            sorted((row.kind, row.entry) for row in rows),
            [("release", "app.dockview"), ("release", "app.sweater")],
        )

    def _world(self):
        return suede.scan(self.consumer, "app", ".", "flag")


class PackageDeclarations(Fixture):
    """`orm` publishes both a package.json and a requirements.txt, the way a
    dependency that needs third-party packages does."""

    graph = {"orm": {}}
    publishes = {
        "orm": {
            "package.json": '{"dependencies": {"zod": "^3.0.0"}}\n',
            "requirements.txt": "# what the library needs\nSQLModel[async] >= 0.0.14\n-r base.txt\n",
        }
    }

    def declare(self, filename, content):
        make_graph.write(self.path(filename), content)

    def read(self, filename):
        with open(self.path(filename), encoding="utf-8") as handle:
            return handle.read()

    def announced(self, *extra):
        captured = io.StringIO()
        with contextlib.redirect_stdout(captured):
            code = self.install("orm", *extra)
        return code, captured.getvalue()

    def test_a_published_requirement_is_merged_verbatim(self):
        self.assertEqual(self.install("orm"), suede.Exit.OK)

        self.assertEqual(self.read("requirements.txt"), "SQLModel[async] >= 0.0.14\n")

    def test_merging_appends_rather_than_rewrites(self):
        self.declare("requirements.txt", "# mine\nrich==13.7.0\n")

        self.install("orm")

        self.assertEqual(self.read("requirements.txt"), "# mine\nrich==13.7.0\nSQLModel[async] >= 0.0.14\n")

    def test_a_requirement_you_already_declare_differently_blocks_and_names_the_flag(self):
        self.declare("requirements.txt", "sqlmodel==0.0.9\n")

        code, output = self.announced()

        self.assertEqual(code, suede.Exit.PRECONDITION)
        self.assertIn(suede.ALLOW_CONFLICTS_FLAG, output)
        self.assertEqual(self.read("requirements.txt"), "sqlmodel==0.0.9\n")
        self.assertFalse(self.exists("app.orm"))

    def test_the_flag_installs_and_leaves_your_own_declaration_alone(self):
        self.declare("requirements.txt", "sqlmodel==0.0.9\n")
        self.declare("package.json", '{"dependencies": {"zod": "^2.0.0"}}\n')

        self.assertEqual(self.install("orm", suede.ALLOW_CONFLICTS_FLAG), suede.Exit.OK)

        self.assertTrue(self.exists("app.orm"))
        self.assertEqual(self.read("requirements.txt"), "sqlmodel==0.0.9\n")
        self.assertEqual(self.read("package.json"), '{"dependencies": {"zod": "^2.0.0"}}\n')

    def test_a_line_naming_no_package_is_reported_rather_than_merged(self):
        code, output = self.announced()

        self.assertEqual(code, suede.Exit.OK)
        self.assertIn("-r base.txt", output)
        self.assertNotIn("-r base.txt", self.read("requirements.txt"))

    def test_a_dev_install_declares_packages_where_nothing_publishes_them(self):
        """`extract` copies `dependencies` and requirements.txt into the
        manifest verbatim, so a dev-only package merged there would be handed
        to every consumer."""
        self.declare("package.json", '{"dependencies": {"svelte": "^5.0.0"}}\n')

        self.assertEqual(self.install("orm", "--dev"), suede.Exit.OK)

        self.assertEqual(
            json.loads(self.read("package.json")),
            {"dependencies": {"svelte": "^5.0.0"}, "devDependencies": {"zod": "^3.0.0"}},
        )
        self.assertEqual(self.read("requirements-dev.txt"), "SQLModel[async] >= 0.0.14\n")
        self.assertFalse(os.path.exists(self.path("requirements.txt")))

    def test_a_dev_install_will_not_declare_a_package_you_already_have(self):
        self.declare("package.json", '{"dependencies": {"zod": "^3.0.0"}}\n')

        self.assertEqual(self.install("orm", "--dev"), suede.Exit.OK)

        self.assertEqual(json.loads(self.read("package.json")), {"dependencies": {"zod": "^3.0.0"}})

    def test_no_python_leaves_requirements_txt_untouched(self):
        self.declare("requirements.txt", "sqlmodel==0.0.9\n")

        self.assertEqual(self.install("orm", "--no-python"), suede.Exit.OK)

        self.assertEqual(self.read("requirements.txt"), "sqlmodel==0.0.9\n")


class DeclarationInvariant(Fixture):
    def test_an_edge_backed_by_an_undeclared_directory_fails_check(self):
        self.install("sweater")
        os.remove(self.path("sweater.dockview"))
        os.rename(self.path("app.dockview"), self.path("undeclared"))
        os.symlink("./undeclared", self.path("sweater.dockview"))

        self.assertEqual(self.suede("check"), suede.Exit.CHECK_FAILED)


if __name__ == "__main__":
    unittest.main()
