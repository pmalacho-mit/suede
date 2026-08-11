"""Prompting, against a real terminal.

`suede.tty` opens `/dev/tty` rather than stdin, because the bootstrap pipes a
`.gitrepo` into stdin. That makes it the one piece of the installer a fake
cannot honestly stand in for: the bug this suite exists to prevent was
`open("/dev/tty", "r+")`, which raises `UnsupportedOperation` on every terminal
there is — a terminal is not seekable, and buffered random-access mode refuses
to wrap anything that isn't. A `pty` is a real terminal, so it reproduces that.
"""

import os
import pty
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "scripts"))

import suede  # noqa: E402


class Terminal:
    """A pty, and the path a separate `open()` can reach it by."""

    def __init__(self):
        self.controller, device = pty.openpty()
        self.path = os.ttyname(device)
        self._device = device

    def types(self, text):
        os.write(self.controller, text.encode())

    def printed(self):
        return os.read(self.controller, 4096).decode()

    def close(self):
        for descriptor in (self.controller, self._device):
            try:
                os.close(descriptor)
            except OSError:
                pass


class Prompting(unittest.TestCase):
    def setUp(self):
        self.terminal = Terminal()
        self.addCleanup(self.terminal.close)

    def ask(self, *answers, **options):
        return suede.tty.ask("Proceed? [Y/n] ", answers, path=self.terminal.path, **options)

    def test_reads_an_answer_from_the_terminal(self):
        self.terminal.types("y\n")

        self.assertEqual(self.ask("y", "n"), "y")

    def test_the_question_reaches_the_terminal(self):
        self.terminal.types("n\n")

        self.ask("y", "n")

        self.assertIn("Proceed?", self.terminal.printed())

    def test_an_empty_line_takes_the_default(self):
        self.terminal.types("\n")

        self.assertEqual(self.ask("y", "n", default="y"), "y")

    def test_an_answer_that_is_not_offered_is_asked_again(self):
        self.terminal.types("maybe\nn\n")

        self.assertEqual(self.ask("y", "n"), "n")

    def test_answers_are_case_insensitive(self):
        self.terminal.types("Y\n")

        self.assertEqual(self.ask("y", "n"), "y")


class NothingToRead(unittest.TestCase):
    """A terminal that answers nothing.

    `/dev/null` stands in for it: reads return EOF and writes go nowhere.
    Closing a pty unlinks its path, and a regular file is worse than useless
    here - the prompt's own output feeds straight back into the reader.
    """

    path = os.devnull

    def test_a_default_is_taken(self):
        self.assertEqual(
            suede.tty.ask("Proceed? ", ("y", "n"), default="n", path=self.path), "n"
        )

    def test_without_a_default_it_refuses_rather_than_spinning(self):
        """Silence is not consent, and it must not be a busy loop either."""
        with self.assertRaises(suede.SuedeError):
            suede.tty.ask("Pick one ", ("1", "2", "3"), path=self.path)


if __name__ == "__main__":
    unittest.main()
