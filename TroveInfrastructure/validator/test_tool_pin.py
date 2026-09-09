"""Release metadata must not weaken a locked tool checksum."""

# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

import unittest

from check_tool_pin import ValidatorPin


class ValidatorPinTests(unittest.TestCase):
    def setUp(self):
        self.pin = ValidatorPin.from_manifest({"validatorVersion": "6.10.4", "validatorSHA256": "a" * 64})
        self.asset = {"name": "validator_cli.jar", "digest": "sha256:" + "a" * 64}
        self.release = {"tag_name": "6.10.4", "draft": False, "prerelease": False, "assets": [self.asset]}

    def test_exact_official_asset_passes(self):
        self.pin.verify_release(self.release)
        self.assertEqual(self.pin.release_api, "repos/hapifhir/org.hl7.fhir.core/releases/tags/6.10.4")

    def test_manifest_cannot_change_repository_or_bypass_digest_validation(self):
        for value in (None, {}, {"validatorVersion": "../../other", "validatorSHA256": "a" * 64},
                      {"validatorVersion": "6.10.4", "validatorSHA256": "sha256:" + "a" * 64},
                      {"validatorVersion": True, "validatorSHA256": "a" * 64},
                      {"validatorVersion": "6.10.4", "validatorSHA256": None}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                ValidatorPin.from_manifest(value)

    def test_wrong_or_unpublished_release_fails(self):
        for key, value in (("tag_name", "6.10.3"), ("draft", True), ("prerelease", True),
                           ("draft", None), ("prerelease", 0)):
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                self.pin.verify_release({**self.release, key: value})

    def test_missing_duplicate_malformed_or_replaced_asset_fails(self):
        for assets in (None, [], [None], [self.asset, self.asset], [{"name": "other.jar", "digest": self.asset["digest"]}],
                       [{"name": "validator_cli.jar"}], [{**self.asset, "digest": "sha256:" + "b" * 64}],
                       [{**self.asset, "digest": self.pin.digest}], [{**self.asset, "digest": None}]):
            with self.subTest(assets=assets), self.assertRaises(ValueError):
                self.pin.verify_release({**self.release, "assets": assets})


if __name__ == "__main__":
    unittest.main()
