# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

from pathlib import Path
import tempfile
import unittest

from check_site import check


class SiteCheckTests(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.site = Path(directory.name)

    def test_valid_relative_and_pages_links(self) -> None:
        (self.site / "index.html").write_text(
            '<a href="guide/#details">Guide</a><a href="/Trove/guide/#details">Guide</a>'
            '<a href="https://example.org/">External</a><img src="image.png">'
            '<source srcset="image.png 1x, image.png 2x">'
        )
        (self.site / "guide").mkdir()
        (self.site / "guide/index.html").write_text('<h1 id="details">Details</h1><a href="../">Home</a>')
        (self.site / "image.png").write_bytes(b"fixture")
        self.assertEqual(check(self.site, "/Trove/"), [])

    def test_missing_targets_anchors_and_base_path_fail(self) -> None:
        for link in ("missing.html", "#absent", "/wrong/", "../escape", "%2e%2e/escape"):
            with self.subTest(link=link):
                (self.site / "index.html").write_text(f'<a href="{link}">Link</a>')
                self.assertTrue(check(self.site, "/Trove/"))

    def test_missing_dark_image_fails(self) -> None:
        (self.site / "index.html").write_text('<picture><source srcset="dark.png"><img src="light.png"></picture>')
        (self.site / "light.png").write_bytes(b"fixture")
        self.assertEqual(len(check(self.site, "/Trove/")), 1)

    def test_missing_homepage_fails(self) -> None:
        self.assertEqual(check(self.site, "/Trove/"), ["Missing homepage"])


if __name__ == "__main__":
    unittest.main()
