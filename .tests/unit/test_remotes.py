"""One repository, three spellings.

A developer pushes over SSH and a consumer reads over HTTPS, so the same
dependency reaches the model written two ways. Everything downstream - dedup,
conflict detection, the declaration invariant - keys on the remote, so the two
spellings agreeing is not a nicety: where they disagree, one dependency becomes
two, and a diamond stops being a diamond.
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "scripts"))

import suede  # noqa: E402

HTTPS = "https://github.com/pmalacho-mit/programmatic-docker-suede"
SSH = "git@github.com:pmalacho-mit/programmatic-docker-suede.git"


class Spellings(unittest.TestCase):
    def test_ssh_and_https_share_one_identity(self):
        self.assertEqual(suede.remotes.canonical(SSH), suede.remotes.canonical(HTTPS))

    def test_a_dot_git_suffix_does_not_make_a_second_repository(self):
        self.assertEqual(suede.remotes.canonical(HTTPS + ".git"), suede.remotes.canonical(HTTPS))

    def test_a_trailing_slash_does_not_either(self):
        self.assertEqual(suede.remotes.canonical(HTTPS + "/"), suede.remotes.canonical(HTTPS))

    def test_the_scheme_form_of_ssh_is_recognised(self):
        self.assertEqual(
            suede.remotes.canonical("ssh://git@github.com/pmalacho-mit/programmatic-docker-suede"),
            suede.remotes.canonical(HTTPS),
        )

    def test_each_spelling_is_derivable_from_the_other(self):
        self.assertEqual(suede.remotes.ssh(HTTPS), SSH)
        self.assertEqual(suede.remotes.https(SSH), HTTPS)

    def test_a_forge_that_is_not_github_works_the_same_way(self):
        self.assertEqual(suede.remotes.ssh("https://gitlab.com/group/sub/proj"), "git@gitlab.com:group/sub/proj.git")

    def test_the_name_is_the_basename_whichever_spelling_arrives(self):
        self.assertEqual(suede.remotes.name(SSH), "programmatic-docker-suede")
        self.assertEqual(suede.remotes.name(HTTPS), "programmatic-docker-suede")


class NotAnAddressWeCanRewrite(unittest.TestCase):
    """Refusing to derive is the safe answer: a URL we invented would fail at
    the worst moment, having named a repository that was never asked for."""

    def test_a_local_path_is_left_exactly_as_it_is(self):
        self.assertEqual(suede.remotes.canonical("/tmp/graph/dockview.git"), "/tmp/graph/dockview.git")
        self.assertEqual(suede.remotes.ssh("/tmp/graph/dockview.git"), "/tmp/graph/dockview.git")

    def test_a_file_url_is_left_alone(self):
        self.assertEqual(suede.remotes.canonical("file:///tmp/x"), "file:///tmp/x")

    def test_a_port_is_left_alone_because_ssh_could_not_carry_it(self):
        forge = "http://localhost:3000/test-org/dep-lib.git"
        self.assertEqual(suede.remotes.canonical(forge), forge)
        self.assertEqual(suede.remotes.candidates(forge), (forge,))

    def test_a_host_without_a_dot_is_not_an_address(self):
        self.assertEqual(suede.remotes.canonical("git@localhost:o/r"), "git@localhost:o/r")

    def test_a_local_path_still_yields_its_name(self):
        self.assertEqual(suede.remotes.name("/tmp/graph/dockview.git"), "dockview")


class WhatToTry(unittest.TestCase):
    def test_ssh_is_tried_before_https(self):
        self.assertEqual(suede.remotes.candidates(HTTPS), (SSH, HTTPS))

    def test_the_order_does_not_depend_on_how_it_was_written(self):
        self.assertEqual(suede.remotes.candidates(SSH), (SSH, HTTPS))

    def test_something_with_one_spelling_is_attempted_once(self):
        self.assertEqual(suede.remotes.candidates("/tmp/x.git"), ("/tmp/x.git",))


class FallingBack(unittest.TestCase):
    """`git.over` decides which spelling actually gets used. It takes the
    reaching as a callable, so the order and the reporting are provable without
    a network."""

    def setUp(self):
        # Whether SSH is worth trying is remembered for the length of a run,
        # and these cases each assume a run that has learned nothing yet.
        suede.git.forget_refusals()

    def reaching(self, works):
        tried = []

        def reach(candidate):
            tried.append(candidate)
            if candidate != works:
                raise suede.SuedeError("nope")
            return candidate

        return tried, reach

    def test_ssh_answering_means_https_is_never_tried(self):
        tried, reach = self.reaching(SSH)

        self.assertEqual(suede.git.over(HTTPS, reach), SSH)
        self.assertEqual(tried, [SSH])

    def test_https_is_tried_when_ssh_fails(self):
        tried, reach = self.reaching(HTTPS)

        self.assertEqual(suede.git.over(HTTPS, reach), HTTPS)
        self.assertEqual(tried, [SSH, HTTPS])

    def test_when_neither_answers_the_failure_names_both(self):
        _, reach = self.reaching("neither")

        with self.assertRaises(suede.SuedeError) as caught:
            suede.git.over(HTTPS, reach)

        self.assertIn(SSH, str(caught.exception))
        self.assertIn(HTTPS, str(caught.exception))

    def test_a_single_spelling_reports_its_own_failure(self):
        """No "tried SSH and HTTPS" for a local path: the message would name
        two URLs that were never attempted, and send the reader after a key
        that was never the problem."""
        tried, reach = self.reaching("neither")

        with self.assertRaises(suede.SuedeError) as caught:
            suede.git.over("/tmp/x.git", reach)

        self.assertEqual(str(caught.exception), "nope")
        self.assertEqual(tried, ["/tmp/x.git"])


class BoundingTheAttempt(unittest.TestCase):
    """An attempt that hangs is worse than one that fails. On a network that
    drops port 22 rather than refusing it, an unbounded SSH attempt is a full
    TCP timeout - paid per remote, before the HTTPS spelling is ever tried."""

    KEYS = ("GIT_SSH_COMMAND", "GIT_TERMINAL_PROMPT")

    def setUp(self):
        self.original = {key: os.environ.get(key) for key in self.KEYS}
        self.addCleanup(self.restore)
        for key in self.KEYS:
            os.environ.pop(key, None)

    def restore(self):
        for key, value in self.original.items():
            os.environ.pop(key, None)
            if value is not None:
                os.environ[key] = value

    def test_ssh_gets_a_connect_timeout_and_refuses_to_prompt(self):
        suede.bound_the_network()

        self.assertIn("ConnectTimeout", os.environ["GIT_SSH_COMMAND"])
        self.assertIn("BatchMode=yes", os.environ["GIT_SSH_COMMAND"])

    def test_https_is_never_allowed_to_stop_and_ask_for_a_password(self):
        suede.bound_the_network()

        self.assertEqual(os.environ["GIT_TERMINAL_PROMPT"], "0")

    def test_what_the_environment_already_says_wins(self):
        """Someone who has named their own ssh command has a reason, and it is
        a better one than ours."""
        os.environ["GIT_SSH_COMMAND"] = "ssh -i /keys/deploy"

        suede.bound_the_network()

        self.assertEqual(os.environ["GIT_SSH_COMMAND"], "ssh -i /keys/deploy")


class PinIdentity(unittest.TestCase):
    """The reason the namespace exists. `Pin` is a dict key in `stage()` and the
    grouping key in the planner, so this is what keeps a diamond a diamond when
    one side was published over HTTPS and the other installed over SSH."""

    def test_two_spellings_of_one_pin_are_the_same_pin(self):
        self.assertEqual(suede.Pin(remote=SSH, commit="a" * 40), suede.Pin(remote=HTTPS, commit="a" * 40))

    def test_and_collapse_in_a_set(self):
        pins = {suede.Pin(remote=SSH, commit="a" * 40), suede.Pin(remote=HTTPS, commit="a" * 40)}
        self.assertEqual(len(pins), 1)

    def test_a_pin_reports_the_canonical_spelling_however_it_was_built(self):
        self.assertEqual(suede.Pin(remote=SSH, commit="a" * 40).remote, HTTPS)


if __name__ == "__main__":
    unittest.main()


class RememberingThatSshIsNoUse(unittest.TestCase):
    """An install makes a dozen remote calls. Where SSH is blocked rather than
    refused, each one pays a full connect timeout - which was six sevenths of
    the wall clock of an install with nothing else wrong with it."""

    def setUp(self):
        suede.git.forget_refusals()

    def reaching_https_only(self):
        tried = []

        def reach(candidate):
            tried.append(candidate)
            if candidate.startswith("git@"):
                raise suede.SuedeError("port 22 is dropped here")
            return candidate

        return tried, reach

    def test_ssh_is_tried_once_per_host_and_not_again(self):
        tried, reach = self.reaching_https_only()

        for _ in range(4):
            self.assertEqual(suede.git.over(HTTPS, reach), HTTPS)

        self.assertEqual(tried.count(SSH), 1)
        self.assertEqual(tried.count(HTTPS), 4)

    def test_another_host_is_still_given_its_own_chance(self):
        tried, reach = self.reaching_https_only()
        suede.git.over(HTTPS, reach)

        suede.git.over("https://gitlab.test/acme/thing.git", reach)

        self.assertIn("git@gitlab.test:acme/thing.git", tried)

    def test_a_host_that_answers_over_ssh_keeps_being_asked(self):
        tried = []

        def reach(candidate):
            tried.append(candidate)
            return candidate

        for _ in range(3):
            self.assertEqual(suede.git.over(HTTPS, reach), SSH)

        self.assertEqual(tried, [SSH, SSH, SSH])
