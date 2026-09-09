"""The real-provider verifier must reject ambiguous identities and unrelated failures."""

# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

import base64
import json
import unittest
from unittest.mock import patch
import uuid

from verify_key_rotation import FixtureToken, await_status, key_provider


def fixture(header, claims):
    def encode(value):
        return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")
    return encode(header) + "." + encode(claims) + ".synthetic-signature"


class KeyRotationTests(unittest.TestCase):
    def test_token_inspection_requires_explicit_key_algorithm_and_integer_expiry(self):
        header, claims = {"alg": "RS256", "kid": "fixture-key"}, {"exp": 2_000_000_000}
        token = fixture(header, claims)
        self.assertEqual(FixtureToken.inspect(token), FixtureToken(token, "fixture-key", 2_000_000_000))
        for value in ("", "a.b", "a.b.c.d", "x" * 16385, fixture({**header, "alg": "none"}, claims),
                      fixture({"alg": "RS256"}, claims), fixture({**header, "kid": ""}, claims),
                      fixture(header, {"exp": True}), fixture(header, {"exp": "2000000000"}), fixture(header, {})):
            with self.subTest(value=value), self.assertRaises((RuntimeError, ValueError)):
                FixtureToken.inspect(value)

    def test_provider_resolution_rejects_ambiguous_or_unsafe_targets(self):
        provider = str(uuid.uuid4())
        item = {"kid": "fixture-key", "algorithm": "RS256", "providerId": provider}
        self.assertEqual(key_provider({"keys": [item]}, "fixture-key"), provider)
        for value in (None, {}, {"keys": []}, {"keys": [item, item]}, {"keys": [{**item, "algorithm": "ES256"}]},
                      {"keys": [{**item, "providerId": "../../other"}]}, {"keys": [{**item, "providerId": None}]}):
            with self.subTest(value=value), self.assertRaises((RuntimeError, ValueError)):
                key_provider(value, "fixture-key")

    def test_poll_allows_only_the_declared_transient_status(self):
        token = FixtureToken("synthetic", "key", 2_000_000_000)
        with patch("verify_key_rotation.probe", side_effect=[401, 200]), \
             patch("verify_key_rotation.time.monotonic", side_effect=[0, 0, 0.5, 0.75]), \
             patch("verify_key_rotation.time.sleep"):
            self.assertEqual(await_status("http://unused", token, 200, 401, 1), 0.75)
        for status in (403, 404, 500, 503):
            with self.subTest(status=status), patch("verify_key_rotation.probe", return_value=status), \
                 patch("verify_key_rotation.time.monotonic", return_value=0), \
                 patch("verify_key_rotation.time.sleep") as sleep, self.assertRaisesRegex(RuntimeError, "Unexpected authentication"):
                await_status("http://unused", token, 200, 401, 1)
            sleep.assert_not_called()

    def test_transient_failure_does_not_count_as_completion(self):
        with patch("verify_key_rotation.probe", return_value=401), \
             patch("verify_key_rotation.time.monotonic", side_effect=[0, 0, 2]), \
             patch("verify_key_rotation.time.sleep"), self.assertRaisesRegex(RuntimeError, "did not reach"):
            await_status("http://unused", FixtureToken("synthetic", "key", 1), 200, 401, 1)


if __name__ == "__main__":
    unittest.main()
