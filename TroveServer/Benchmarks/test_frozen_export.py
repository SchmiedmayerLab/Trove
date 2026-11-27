# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT
import hashlib
import io
import unittest

from frozen_export import verify_download


class FrozenExportTests(unittest.TestCase):
    def test_index_matches_exact_ndjson_bytes(self):
        lines = [b'{"id":"one"}', b'{"id":"two"}']
        data = b"\n".join(lines) + b"\n"
        members = [{"line": n, "byteCount": len(line), "sha256": hashlib.sha256(line).hexdigest()}
                   for n, line in enumerate(lines, start=1)]
        manifest = {"recordCount": 2, "byteCount": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        verify_download(io.BytesIO(data), manifest, members)
        for changed, index in [(data[:-1], members), (data + b"\n", members), (data, members[::-1]),
                               (data.replace(b"two", b"one"), members), (data, members[:1])]:
            with self.subTest(changed=changed, index=index), self.assertRaises(ValueError):
                verify_download(io.BytesIO(changed), manifest, index)
