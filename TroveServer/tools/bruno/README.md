<!--
This source file is part of the Trove open-source project

SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT
-->

# Manual Study Authoring

Run **Get Study** and review its response before changing a study, component or
schedule. The collection captures `draftRevision` and sends it as `If-Match`.
Every successful write invalidates that revision; run **Get Study** again before
the next write. A `412` requires reviewing the changed draft, not blindly retrying
the previous edit. Requests never fetch a new revision or retry automatically.

For publication, run **Validate Study** after reviewing the draft. Inspect the
returned archive digest, questionnaire evidence, validator identity and expiry.
Then explicitly run **Publish Study** as an administrator. It uses the captured
validation ID and validated revision, not the latest draft revision. Keep that
pair for an exact retry after a lost response. Publishing never performs implicit
validation. A candidate for another study cannot be reused.

The **Seed** request only builds a synthetic draft; it does not validate or publish
it. Validation requires the configured pinned validator and supported Questionnaire
content. Existing sample questionnaire JSON is an authoring example, not a claim
of current IG conformance.
