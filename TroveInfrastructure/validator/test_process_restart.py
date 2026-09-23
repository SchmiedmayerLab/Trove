"""Revision-bound authoring setup without network or container dependencies."""

# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

import unittest
from unittest.mock import Mock, patch
import uuid

from verify_process_restart import Checkpoint, response_uuid


class ProcessRestartAuthoringTests(unittest.TestCase):
    def test_validation_and_publication_use_the_same_reviewed_revision(self):
        study, revision, candidate_id = [str(uuid.uuid4()) for _ in range(3)]
        checkpoint = object.__new__(Checkpoint)
        checkpoint.api_json = Mock(side_effect=[
            {"id": candidate_id, "draftRevision": revision, "publicationRevision": 1},
            {"id": candidate_id, "studyId": study, "revision": 1},
        ])
        checkpoint.publish_draft(study, "synthetic-token", revision)
        validation, publication = checkpoint.api_json.call_args_list
        self.assertEqual(validation.args[0], f"/studies/{study}/draft/validations")
        self.assertEqual(publication.args, (f"/studies/{study}/publish", "synthetic-token", "POST", {"validationId": candidate_id}))
        self.assertEqual(validation.kwargs["headers"], {"If-Match": f'"{revision}"'})
        self.assertEqual(publication.kwargs["headers"], validation.kwargs["headers"])

    def test_malformed_or_mismatched_candidate_never_reaches_publication(self):
        study, revision, candidate_id = [str(uuid.uuid4()) for _ in range(3)]
        for candidate in ({}, {"id": "invalid"},
                          {"id": candidate_id, "draftRevision": str(uuid.uuid4()), "publicationRevision": 1},
                          {"id": candidate_id, "draftRevision": revision, "publicationRevision": True}):
            with self.subTest(candidate=candidate):
                checkpoint = object.__new__(Checkpoint)
                checkpoint.api_json = Mock(return_value=candidate)
                with self.assertRaises(RuntimeError):
                    checkpoint.publish_draft(study, "synthetic-token", revision)
                self.assertEqual(checkpoint.api_json.call_count, 1)

    def test_publication_receipt_must_match_the_candidate(self):
        study, revision, candidate_id = [str(uuid.uuid4()) for _ in range(3)]
        for field, value in (("id", str(uuid.uuid4())), ("studyId", str(uuid.uuid4())), ("revision", 2)):
            checkpoint = object.__new__(Checkpoint)
            published = {"id": candidate_id, "studyId": study, "revision": 1, field: value}
            checkpoint.api_json = Mock(side_effect=[
                {"id": candidate_id, "draftRevision": revision, "publicationRevision": 1}, published,
            ])
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                checkpoint.publish_draft(study, "synthetic-token", revision)
            self.assertEqual(checkpoint.api_json.call_count, 2)

    def test_api_helper_forwards_precondition_and_rejects_missing_identity(self):
        checkpoint = object.__new__(Checkpoint)
        checkpoint.api = "http://127.0.0.1:8080/api/v0"
        with patch("verify_process_restart.request", return_value=b"{}") as request:
            checkpoint.api_json("/studies/example", "synthetic-token", "PATCH", {}, headers={"If-Match": '"revision"'})
            self.assertEqual(request.call_args.kwargs["headers"], {"If-Match": '"revision"'})
        for response in (None, [], {}, {"id": 1}, {"id": "invalid"}):
            with self.subTest(response=response), self.assertRaises(RuntimeError):
                response_uuid(response, "id")


if __name__ == "__main__":
    unittest.main()
