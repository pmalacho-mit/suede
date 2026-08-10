"""The boundary that makes everything else cheap to test.

The moment `plan()` or `check()` calls git, the scenario matrix stops being
literals and starts being fixtures. This asserts the boundary rather than
trusting a review rule to hold it.
"""

import unittest

from support import manifest, pin, request, suede, world

A = pin("A", "a")
B = pin("B", "b")


class RefusesToRun:
    """Stands in for the git layer and fails on any use at all."""

    def __getattr__(self, name):
        raise AssertionError("the planner called git.%s" % name)


class PureOverTheModel(unittest.TestCase):
    def setUp(self):
        self.real_git = suede.git
        suede.git = RefusesToRun()
        self.addCleanup(setattr, suede, "git", self.real_git)

    def test_planning_touches_no_git(self):
        manifests = {A: manifest({"A.B": B}), B: manifest()}

        plan = suede.plan(world(), request(A), suede.Policy(), manifests)

        self.assertTrue(plan.acts)

    def test_checking_touches_no_git(self):
        tree = world(installs={"app.B": B}, edges=[("app.B", "B.C", A)])

        self.assertTrue(suede.check(tree))

    def test_announcing_touches_no_git(self):
        plan = suede.plan(world(), request(A), suede.Policy(), {A: manifest()})

        self.assertIn("install", suede.announce(world(), plan, request(A)))
        self.assertIn('"version": 1', suede.plan_json(world(), plan, request(A)))

    def test_listing_touches_no_git(self):
        tree = world(installs={"app.B": B})

        self.assertEqual(len(suede.listing(tree)), 1)


if __name__ == "__main__":
    unittest.main()
