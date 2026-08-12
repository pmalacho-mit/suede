"""Reading a `requirements.txt`.

The merge is only as honest as this read: a line misread as a package gets
declared into a consumer's own file, and a package missed is a dependency that
does not run. The file is the input, so these live here rather than in the
pure suites.
"""

import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "scripts"))

import suede  # noqa: E402


class Reading(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.mkdtemp(prefix="suede-requirements-")
        self.addCleanup(shutil.rmtree, self.directory, True)

    def read(self, content):
        path = os.path.join(self.directory, "requirements.txt")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(content)
        return suede.pip.read(path)

    def test_a_missing_file_declares_nothing(self):
        self.assertEqual(suede.pip.read(os.path.join(self.directory, "absent.txt")), ({}, ()))

    def test_comments_and_blank_lines_are_not_requirements(self):
        requirements, extras = self.read("# a note\n\nhttpx==0.27.0   # why\n")

        self.assertEqual(requirements, {"httpx": "httpx==0.27.0"})
        self.assertEqual(extras, ())

    def test_extras_and_markers_travel_with_the_requirement(self):
        line = 'SQLModel[async] >= 0.0.14 ; python_version < "3.13"'

        requirements, _ = self.read(line + "\n")

        self.assertEqual(requirements, {"sqlmodel": line})

    def test_names_are_compared_the_way_pypi_compares_them(self):
        requirements, _ = self.read("Zope.Interface==5.0\n")

        self.assertEqual(sorted(requirements), ["zope-interface"])
        self.assertEqual(suede.pip.normalize("ruamel__yaml.clib"), "ruamel-yaml-clib")

    def test_a_continued_line_is_one_requirement(self):
        requirements, _ = self.read("httpx==0.27.0 \\\n    --hash=sha256:abc\n")

        self.assertEqual(sorted(requirements), ["httpx"])

    def test_options_and_urls_name_no_package(self):
        requirements, extras = self.read(
            "-r base.txt\n"
            "--index-url https://example.test/simple\n"
            "-e ./local\n"
            "git+https://example.test/acme/widget#egg=widget\n"
            "https://example.test/widget-1.0.whl\n"
        )

        self.assertEqual(requirements, {})
        self.assertEqual(len(extras), 5)

    def test_a_direct_reference_still_names_its_package(self):
        line = "widget @ git+https://example.test/acme/widget"

        requirements, extras = self.read(line + "\n")

        self.assertEqual(requirements, {"widget": line})
        self.assertEqual(extras, ())


if __name__ == "__main__":
    unittest.main()
