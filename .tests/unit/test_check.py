"""What `check` does and does not fail on.

The three comparisons that get confused with each other have different
verdicts, and the difference is the point: the declaration invariant is
structural, which is exactly what frees the pin comparisons to be
informational.
"""

import unittest

from support import manifest, pin, request, suede, world

B = pin("B", "b")
C = pin("C", "c")
C_OTHER = pin("C", "9")
LEGACY = suede.LEGACY_MANIFEST_DIR


def levels(findings, code):
    return [finding.level for finding in findings if finding.code == code]


def codes(findings):
    return sorted({finding.code for finding in findings})


class DeclarationInvariant(unittest.TestCase):
    def test_an_edge_satisfied_by_an_undeclared_directory_fails(self):
        tree = world(
            installs={"app.B": B, "vendor/C": C},
            links={"B.C": "vendor/C"},
            edges=[("app.B", "B.C", C)],
        )

        self.assertEqual(levels(suede.check(tree), "undeclared-edge"), ["FAIL"])

    def test_an_edge_satisfied_by_a_declared_directory_passes(self):
        tree = world(
            installs={"app.B": B, "app.C": C},
            links={"B.C": "app.C"},
            edges=[("app.B", "B.C", C)],
        )

        self.assertEqual(suede.check(tree), ())

    def test_a_symlinked_declaration_is_as_good_as_a_folder(self):
        tree = world(
            installs={"app.B": B, "deps/C": C},
            links={"app.C": "deps/C", "B.C": "deps/C"},
            edges=[("app.B", "B.C", C)],
        )

        self.assertEqual(suede.check(tree), ())


class MissingEdges(unittest.TestCase):
    def test_a_manifest_entry_with_no_sibling_at_all_fails(self):
        tree = world(installs={"app.B": B}, edges=[("app.B", "B.C", C)])

        self.assertEqual(levels(suede.check(tree), "missing-edge"), ["FAIL"])

    def test_a_dangling_sibling_fails_the_same_way(self):
        tree = world(installs={"app.B": B}, links={"B.C": None}, edges=[("app.B", "B.C", C)])

        self.assertEqual(levels(suede.check(tree), "missing-edge"), ["FAIL"])


class PinComparisons(unittest.TestCase):
    """You took ownership of the resolution. Surface it; never fail on it."""

    def test_a_different_commit_than_the_dependent_asked_for_is_information(self):
        tree = world(
            installs={"app.B": B, "app.C": C_OTHER},
            links={"B.C": "app.C"},
            edges=[("app.B", "B.C", C)],
        )

        findings = suede.check(tree)
        self.assertEqual(levels(findings, "pin-differs"), ["INFO"])
        self.assertEqual(suede.worst(findings), "INFO")

    def test_a_different_remote_than_the_dependent_asked_for_is_information(self):
        forked = pin("C", "f", remote="https://example.test/fork/C")
        tree = world(
            installs={"app.B": B, "app.C": forked},
            links={"B.C": "app.C"},
            edges=[("app.B", "B.C", C)],
        )

        findings = suede.check(tree)
        self.assertEqual(levels(findings, "remote-differs"), ["INFO"])
        self.assertEqual(suede.worst(findings), "INFO")


class DanglingEntries(unittest.TestCase):
    def test_a_prefixed_entry_that_does_not_resolve_warns(self):
        tree = world(links={"app.C": None})

        self.assertEqual(levels(suede.check(tree), "dangling-entry"), ["WARN"])

    def test_a_prefixed_folder_without_a_gitrepo_warns(self):
        tree = world(links={"app.C": "somewhere-else"})

        self.assertEqual(levels(suede.check(tree), "dangling-entry"), ["WARN"])


class CaseCollisions(unittest.TestCase):
    def test_entries_differing_only_by_case_warn(self):
        tree = world(installs={"app.C": C}, links={"app.c": "app.C"})

        self.assertEqual(levels(suede.check(tree), "case-collision"), ["WARN"])


class Classification(unittest.TestCase):
    def test_the_separator_is_part_of_the_prefix(self):
        """`suede-extras/` in a repo named `suede` is not a release dependency."""
        tree = world(repo="suede", installs={"suede-extras": C})

        self.assertEqual(suede.declarations.by_name(tree), {})
        self.assertEqual(
            [row.kind for row in suede.listing(tree)],
            ["development"],
        )

    def test_a_prefixed_entry_is_a_release_dependency(self):
        tree = world(repo="suede", installs={"suede.C": C})

        self.assertEqual([row.kind for row in suede.listing(tree)], ["release"])

    def test_a_repo_name_containing_dots_still_matches_verbatim(self):
        tree = world(repo="my.app", installs={"my.app.C": C})

        self.assertEqual(sorted(suede.declarations.by_name(tree)), ["my.app.C"])

    def test_code_inside_release_is_vendored_and_can_never_satisfy_an_edge(self):
        tree = world(vendored=("release/.suede/vendor/C",))

        rows = suede.listing(tree)
        self.assertEqual([row.kind for row in rows], ["vendored"])
        self.assertEqual(suede.check(tree), ())


class SuedeMachinery(unittest.TestCase):
    """A dependency vendors its workflows and core scripts from suede itself.
    Those are subrepos too, and they are not dependencies."""

    def test_the_vendored_core_is_not_a_dependency(self):
        tree = world(installs={".suede/core": C, ".suede/devcontainers-suede": B})

        self.assertEqual([row.path for row in suede.listing(tree)], [".suede/devcontainers-suede"])

    def test_vendored_workflows_are_not_a_dependency(self):
        tree = world(installs={".github/workflows": C}, vendored=("release/.suede/core",))

        self.assertEqual(suede.listing(tree), ())

    def test_the_rule_is_the_path_not_the_name(self):
        self.assertTrue(suede.declarations.is_machinery(".suede/core"))
        self.assertTrue(suede.declarations.is_machinery("release/.suede/core"))
        self.assertFalse(suede.declarations.is_machinery(".suede/core-utils"))
        self.assertFalse(suede.declarations.is_machinery("my.core"))


class DivergenceTargets(unittest.TestCase):
    """The asymmetry that keeps the vendor escape hatch working."""

    def test_release_dependencies_are_checked(self):
        tree = world(installs={"app.C": C})

        self.assertEqual([entry for entry, _ in suede.divergence_targets(tree)], ["app.C"])

    def test_a_development_dependency_is_not_checked(self):
        tree = world(installs={"tools/helper": C})

        self.assertEqual(suede.divergence_targets(tree), ())

    def test_a_vendored_dependency_is_not_checked(self):
        tree = world(vendored=("release/.suede/vendor/C",))

        self.assertEqual(suede.divergence_targets(tree), ())


class LegacyManifest(unittest.TestCase):
    def test_a_dependency_publishing_the_old_path_is_named_in_the_plan(self):
        legacy = suede.Manifest(edges={"C": C}, legacy=True)

        plan = suede.plan(world(), request(B), suede.Policy(), {B: legacy, C: manifest()})

        self.assertTrue(any(LEGACY in warning for warning in plan.warnings))


class Removal(unittest.TestCase):
    def test_reports_what_becomes_unreferenced_without_deleting_it(self):
        tree = world(
            installs={"app.B": B, "app.C": C},
            links={"B.C": "app.C"},
            edges=[("app.B", "B.C", C)],
            records={"app.B": B, "app.C": C},
        )

        removal = suede.plan_removal(tree, "app.B")

        self.assertEqual(removal.orphans, ("app.C",))
        self.assertNotIn("app.C", removal.removed)
        self.assertIn("app.B", removal.removed)

    def test_refuses_an_entry_that_is_not_a_declared_dependency(self):
        with self.assertRaises(suede.Usage):
            suede.plan_removal(world(), "app.nothing")


if __name__ == "__main__":
    unittest.main()
