"""The planner scenario matrix.

Every assertion here is provable against a literal `World`, which is the whole
reason the planner performs no I/O. Anything that needs a real repository
belongs in the integration suite instead.
"""

import unittest

from support import ancestry, entries_of, manifest, ops, pin, request, suede, world

A = pin("A", "a")
B = pin("B", "b")
C = pin("C", "c")
C_OLD = pin("C", "1")
C_NEW = pin("C", "2")
D = pin("D", "d")


class SingleDependency(unittest.TestCase):
    def test_installs_once_and_records_it(self):
        plan = suede.plan(world(), request(A), suede.Policy(), {A: manifest()})

        self.assertEqual(entries_of(plan, "install"), ["app.A"])
        self.assertEqual(entries_of(plan, "record"), ["app.A"])
        self.assertEqual(ops(plan, "link"), [])

    def test_a_consumer_without_a_release_folder_records_nothing(self):
        plan = suede.plan(world(has_release=False), request(A), suede.Policy(), {A: manifest()})

        self.assertEqual(entries_of(plan, "install"), ["app.A"])
        self.assertEqual(ops(plan, "record"), [])


class Chain(unittest.TestCase):
    """A -> B -> C. Every pin in the closure is the root's own release
    dependency; the dependents get links."""

    manifests = {A: manifest({"A.B": B}), B: manifest({"B.C": C}), C: manifest()}

    def test_installs_the_whole_closure_flat_at_the_root(self):
        plan = suede.plan(world(), request(A), suede.Policy(), self.manifests)

        self.assertEqual(entries_of(plan, "install"), ["app.A", "app.B", "app.C"])
        self.assertEqual(entries_of(plan, "link"), ["A.B", "B.C"])
        self.assertEqual(entries_of(plan, "record"), ["app.A", "app.B", "app.C"])

    def test_links_point_at_the_root_install(self):
        plan = suede.plan(world(), request(A), suede.Policy(), self.manifests)

        self.assertEqual([act.target for act in ops(plan, "link")], ["./app.B", "./app.C"])

    def test_names_a_transitive_install_after_the_dependent_that_needs_it(self):
        plan = suede.plan(world(), request(A), suede.Policy(), self.manifests)

        reasons = {act.entry: act.reason for act in ops(plan, "install")}
        self.assertEqual(reasons["app.A"], "requested")
        self.assertEqual(reasons["app.C"], "required by B")


class Diamond(unittest.TestCase):
    """A depends on B and D; both depend on C."""

    def manifests(self, from_b, from_d):
        return {
            A: manifest({"A.B": B, "A.D": D}),
            B: manifest({"B.C": from_b}),
            D: manifest({"D.C": from_d}),
            from_b: manifest(),
            from_d: manifest(),
        }

    def test_one_install_of_c_when_both_want_the_same_commit(self):
        plan = suede.plan(world(), request(A), suede.Policy(), self.manifests(C, C))

        self.assertEqual(entries_of(plan, "install"), ["app.A", "app.B", "app.C", "app.D"])
        self.assertEqual(sorted(entries_of(plan, "link")), ["A.B", "A.D", "B.C", "D.C"])

    def test_competing_commits_conflict_instead_of_installing_either(self):
        plan = suede.plan(world(), request(A), suede.Policy(), self.manifests(C_OLD, C_NEW))

        self.assertEqual(len(plan.conflicts), 1)
        self.assertNotIn("app.C", entries_of(plan, "install"))
        self.assertEqual(
            sorted({option.id for option in plan.conflicts[0].options}),
            ["coexist", "defer", "unify"],
        )

    def test_a_conflict_names_both_claimants(self):
        plan = suede.plan(world(), request(A), suede.Policy(), self.manifests(C_OLD, C_NEW))

        claims = plan.conflicts[0].claims
        self.assertEqual([claim.dependent for claim in claims], ["B", "D"])
        self.assertFalse(plan.conflicts[0].involves_root)

    def test_coexist_installs_both_and_suffixes_the_newcomer(self):
        plan = suede.plan(
            world(),
            request(A),
            suede.Policy(on_conflict="coexist"),
            self.manifests(C_OLD, C_NEW),
        )

        self.assertEqual(plan.conflicts, ())
        self.assertIn("app.C", entries_of(plan, "install"))
        self.assertIn("app.C-" + C_NEW.short, entries_of(plan, "install"))

    def test_coexist_keeps_each_edge_on_its_own_pin(self):
        plan = suede.plan(
            world(),
            request(A),
            suede.Policy(on_conflict="coexist"),
            self.manifests(C_OLD, C_NEW),
        )

        targets = {act.entry: act.target for act in ops(plan, "link")}
        self.assertEqual(targets["B.C"], "./app.C")
        self.assertEqual(targets["D.C"], "./app.C-" + C_NEW.short)

    def test_unify_newest_installs_only_the_descendant(self):
        plan = suede.plan(
            world(),
            request(A),
            suede.Policy(on_conflict="unify-newest"),
            self.manifests(C_OLD, C_NEW),
            ancestry((C_OLD, C_NEW)),
        )

        installed = [act for act in ops(plan, "install") if act.entry.startswith("app.C")]
        self.assertEqual([act.pin for act in installed], [C_NEW])
        self.assertEqual({act.target for act in ops(plan, "link") if act.entry.endswith(".C")},
                         {"./app.C"})

    def test_unify_newest_refuses_to_guess_on_diverged_history(self):
        plan = suede.plan(
            world(),
            request(A),
            suede.Policy(on_conflict="unify-newest"),
            self.manifests(C_OLD, C_NEW),
            {(C_OLD.commit, C_NEW.commit): False, (C_NEW.commit, C_OLD.commit): False},
        )

        self.assertEqual(len(plan.conflicts), 1)
        self.assertEqual(plan.conflicts[0].ancestry, "diverged")


class RootAsClaimant(unittest.TestCase):
    def test_the_root_is_named_as_a_claimant_and_coexist_leads(self):
        manifests = {B: manifest({"B.C": C_OLD}), C_NEW: manifest(), C_OLD: manifest()}

        plan = suede.plan(world(), request(B, C_NEW), suede.Policy(), manifests)

        conflict = plan.conflicts[0]
        self.assertTrue(conflict.involves_root)
        self.assertIsNone(conflict.claims[0].dependent)
        self.assertEqual(conflict.options[0].id, "coexist")


class Cycle(unittest.TestCase):
    def test_a_to_b_to_a_terminates_and_installs_each_pin_once(self):
        manifests = {A: manifest({"A.B": B}), B: manifest({"B.A": A})}

        plan = suede.plan(world(), request(A), suede.Policy(), manifests)

        self.assertEqual(entries_of(plan, "install"), ["app.A", "app.B"])
        self.assertEqual(sorted(entries_of(plan, "link")), ["A.B", "B.A"])


class Idempotency(unittest.TestCase):
    def test_a_satisfied_tree_plans_nothing_at_all(self):
        satisfied = world(
            installs={"app.A": A, "app.B": B},
            links={"A.B": "app.B"},
            records={"app.A": A, "app.B": B},
        )

        plan = suede.plan(satisfied, request(A), suede.Policy(), {A: manifest({"A.B": B}), B: manifest()})

        self.assertEqual(plan.acts, ())
        self.assertEqual(plan.conflicts, ())


class ConsumerResolution(unittest.TestCase):
    """The consumer's declared root entry wins, and is announced, not challenged."""

    def test_an_edge_already_backed_by_a_declared_entry_is_an_override(self):
        """B asks for C; this project resolved B's edge to a fork of C and
        declared it. The fork wins, and C itself is never installed."""
        forked = pin("C", "f", remote="https://example.test/fork/C")
        tree = world(
            installs={"app.B": B, "app.C": forked},
            links={"B.C": "app.C"},
            records={"app.B": B, "app.C": forked},
        )
        manifests = {A: manifest({"A.B": B}), B: manifest({"B.C": C})}

        plan = suede.plan(tree, request(A), suede.Policy(), manifests)

        self.assertEqual(entries_of(plan, "override"), ["B.C"])
        self.assertEqual(plan.conflicts, ())
        self.assertEqual(entries_of(plan, "install"), ["app.A"])

    def test_one_declared_entry_at_another_commit_is_an_override_not_a_conflict(self):
        tree = world(installs={"app.C": C_NEW}, records={"app.C": C_NEW})

        plan = suede.plan(
            tree, request(B), suede.Policy(), {B: manifest({"B.C": C_OLD}), C_OLD: manifest()}
        )

        self.assertEqual(entries_of(plan, "override"), ["B.C"])
        self.assertEqual(plan.conflicts, ())
        self.assertEqual(entries_of(plan, "install"), ["app.B"])

    def test_two_declared_entries_and_no_exact_match_is_ambiguous(self):
        tree = world(
            installs={"app.C": C_NEW, "app.C-" + C_OLD.short: C_OLD},
            records={"app.C": C_NEW},
        )
        wanted = pin("C", "3")

        plan = suede.plan(tree, request(B), suede.Policy(), {B: manifest({"B.C": wanted})})

        self.assertEqual([conflict.kind for conflict in plan.conflicts], ["ambiguous"])
        self.assertEqual(entries_of(plan, "install"), ["app.B"])
        self.assertEqual(ops(plan, "link"), [])


class Naming(unittest.TestCase):
    def test_each_dependent_keeps_its_own_separator_verbatim(self):
        manifests = {
            A: manifest({"A.B": B, "A.D": D}),
            B: manifest({"B__C": C}),
            D: manifest({"D.C": C}),
            C: manifest(),
        }

        plan = suede.plan(world(), request(A), suede.Policy(), manifests)

        self.assertIn("B__C", entries_of(plan, "link"))
        self.assertIn("D.C", entries_of(plan, "link"))
        self.assertEqual(len([act for act in ops(plan, "install") if act.pin == C]), 1)

    def test_two_remotes_with_the_same_basename_get_distinct_entries(self):
        other = pin("C", "9", remote="https://example.test/other/C")
        manifests = {A: manifest({"A.C": C, "A.other": other}), C: manifest(), other: manifest()}

        plan = suede.plan(world(), request(A), suede.Policy(), manifests)

        self.assertEqual(
            sorted(entries_of(plan, "install")),
            sorted(["app.A", "app.C", "app.C-" + other.short]),
        )

    def test_an_existing_entry_is_never_renamed_for_a_newcomer(self):
        tree = world(files=["app.A"])

        plan = suede.plan(tree, request(A), suede.Policy(), {A: manifest()})

        self.assertEqual(entries_of(plan, "install"), ["app.A-" + A.short])

    def test_the_name_override_applies_only_to_what_was_asked_for(self):
        manifests = {A: manifest({"A.B": B}), B: manifest()}

        plan = suede.plan(world(), request(A, name="vendor-a"), suede.Policy(), manifests)

        self.assertEqual(sorted(entries_of(plan, "install")), ["app.B", "vendor-a"])


class UnbornHead(unittest.TestCase):
    def test_refuses_to_plan_before_the_first_commit(self):
        plan = suede.plan(world(head=None), request(A), suede.Policy(), {A: manifest()})

        self.assertTrue(plan.blockers)
        self.assertEqual(plan.acts, ())


class RelocatedInstall(unittest.TestCase):
    def test_target_writes_each_edge_beside_the_install_and_at_the_root(self):
        manifests = {A: manifest({"A.B": B}), B: manifest()}

        plan = suede.plan(world(), request(A, target="deps"), suede.Policy(), manifests)

        self.assertEqual(sorted(entries_of(plan, "link")), ["A.B", "deps/A.B"])
        self.assertEqual({act.dest for act in ops(plan, "install")}, {"deps/app.A", "deps/app.B"})

    def test_the_edge_beside_the_install_points_at_a_sibling(self):
        manifests = {A: manifest({"A.B": B}), B: manifest()}

        plan = suede.plan(world(), request(A, target="deps"), suede.Policy(), manifests)

        targets = {act.entry: act.target for act in ops(plan, "link")}
        self.assertEqual(targets["deps/A.B"], "./app.B")
        self.assertEqual(targets["A.B"], "./deps/app.B")


class NpmDependencies(unittest.TestCase):
    def test_missing_entries_are_added(self):
        manifests = {A: manifest(npm={"svelte": "^5.41.0"})}

        plan = suede.plan(world(), request(A), suede.Policy(), manifests)

        self.assertEqual(entries_of(plan, "npm"), ["svelte@^5.41.0"])

    def test_a_range_that_disagrees_stops_the_plan_rather_than_being_resolved(self):
        manifests = {A: manifest(npm={"svelte": "^5.41.0"})}

        plan = suede.plan(world(npm={"svelte": "^4.0.0"}), request(A), suede.Policy(), manifests)

        self.assertTrue(plan.blockers)

    def test_no_npm_leaves_package_json_alone(self):
        manifests = {A: manifest(npm={"svelte": "^5.41.0"})}

        plan = suede.plan(world(), request(A), suede.Policy(npm=False), manifests)

        self.assertEqual(ops(plan, "npm"), [])


class PythonDependencies(unittest.TestCase):
    def test_missing_requirements_are_added_verbatim(self):
        manifests = {A: manifest(python={"sqlmodel": "sqlmodel[async]>=0.0.14; python_version<'3.13'"})}

        plan = suede.plan(world(), request(A), suede.Policy(), manifests)

        self.assertEqual(
            entries_of(plan, "pip"), ["sqlmodel[async]>=0.0.14; python_version<'3.13'"]
        )

    def test_a_requirement_that_disagrees_stops_the_plan(self):
        manifests = {A: manifest(python={"sqlmodel": "sqlmodel>=0.0.14"})}

        plan = suede.plan(
            world(python={"sqlmodel": "sqlmodel==0.0.9"}), request(A), suede.Policy(), manifests
        )

        self.assertTrue(plan.blockers)
        self.assertEqual(ops(plan, "pip"), [])

    def test_no_python_leaves_requirements_alone(self):
        manifests = {A: manifest(python={"sqlmodel": "sqlmodel>=0.0.14"})}

        plan = suede.plan(world(), request(A), suede.Policy(python=False), manifests)

        self.assertEqual(ops(plan, "pip"), [])

    def test_lines_naming_no_package_are_reported_rather_than_merged(self):
        manifests = {A: manifest(python_extras=("-r base.txt",))}

        plan = suede.plan(world(), request(A), suede.Policy(), manifests)

        self.assertEqual(ops(plan, "pip"), [])
        self.assertTrue(any("-r base.txt" in warning for warning in plan.warnings))


class ConflictingPackages(unittest.TestCase):
    """The blocker must name its own way out, and taking it must change nothing
    about what the consumer already declared."""

    CONFLICTED = {
        A: manifest(npm={"svelte": "^5.41.0"}, python={"sqlmodel": "sqlmodel>=0.0.14"})
    }

    def declared(self):
        return world(npm={"svelte": "^4.0.0"}, python={"sqlmodel": "sqlmodel==0.0.9"})

    def test_the_blocker_names_the_flag_that_gets_past_it(self):
        plan = suede.plan(self.declared(), request(A), suede.Policy(), self.CONFLICTED)

        self.assertTrue(
            any(suede.ALLOW_CONFLICTS_FLAG in blocker for blocker in plan.blockers),
            plan.blockers,
        )

    def test_the_flag_installs_and_keeps_every_declaration_of_yours(self):
        allowed = suede.Policy(allow_package_conflicts=True)

        plan = suede.plan(self.declared(), request(A), allowed, self.CONFLICTED)

        self.assertEqual(plan.blockers, ())
        self.assertTrue(entries_of(plan, "install"))
        self.assertEqual(ops(plan, "npm"), [])
        self.assertEqual(ops(plan, "pip"), [])

    def test_what_was_kept_is_said_out_loud(self):
        allowed = suede.Policy(allow_package_conflicts=True)

        plan = suede.plan(self.declared(), request(A), allowed, self.CONFLICTED)

        kept = [warning for warning in plan.warnings if "Kept yours" in warning]
        self.assertEqual(len(kept), 2, plan.warnings)
        self.assertTrue(any("svelte" in warning for warning in kept))
        self.assertTrue(any("sqlmodel" in warning for warning in kept))

    def test_the_flag_leaves_agreeing_packages_merging_as_usual(self):
        manifests = {
            A: manifest(npm={"svelte": "^5.41.0", "zod": "^3.0.0"}),
        }
        allowed = suede.Policy(allow_package_conflicts=True)

        plan = suede.plan(world(npm={"svelte": "^4.0.0"}), request(A), allowed, manifests)

        self.assertEqual(entries_of(plan, "npm"), ["zod@^3.0.0"])

    def test_two_dependencies_disagreeing_with_each_other_never_blocks(self):
        manifests = {
            A: manifest(npm={"svelte": "^5.41.0"}),
            B: manifest(npm={"svelte": "^4.0.0"}),
        }

        plan = suede.plan(world(), request(A, B), suede.Policy(), manifests)

        self.assertEqual(plan.blockers, ())
        self.assertEqual(entries_of(plan, "npm"), ["svelte@^5.41.0"])
        self.assertTrue(any("reconcile them yourself" in w for w in plan.warnings), plan.warnings)


class Determinism(unittest.TestCase):
    def test_acts_are_ordered_by_operation_then_entry(self):
        manifests = {A: manifest({"A.B": B}), B: manifest({"B.C": C}), C: manifest()}

        plan = suede.plan(world(), request(A), suede.Policy(), manifests)

        order = [suede.OP_ORDER.index(act.op) for act in plan.acts]
        self.assertEqual(order, sorted(order))
        self.assertEqual(entries_of(plan, "install"), sorted(entries_of(plan, "install")))


class PlanJson(unittest.TestCase):
    def test_the_document_is_versioned_and_carries_the_acts(self):
        import json

        plan = suede.plan(world(), request(A), suede.Policy(), {A: manifest()})
        document = json.loads(suede.plan_json(world(), plan, request(A)))

        self.assertEqual(document["version"], 1)
        self.assertEqual(document["acts"][0]["op"], "install")
        self.assertEqual(document["acts"][0]["pin"]["commit"], A.commit)


if __name__ == "__main__":
    unittest.main()
