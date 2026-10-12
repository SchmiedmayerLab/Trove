// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { expect, it, vi } from "vitest";
import {
  publicationNeedsReview,
  publicationRequest,
  validationRequest,
} from "./publication";
import { ApiError } from "../api/client";
import type { StudyDraftValidation } from "../api/generated/types.gen";

vi.mock("../env", () => ({
  env: { VITE_API_BASE_PATH: "https://api.example.test" },
}));

const candidate: StudyDraftValidation = {
  id: "b0dd46a5-5138-47b4-8e89-682ea91f1d72",
  draftRevision: "49d6ee6d-e8f9-4458-b122-e660419ecfb8",
  publicationRevision: 3,
  bundleSha256: "0".repeat(64),
  validatorIdentity: "synthetic-validator",
  contractRevision: "synthetic-contract",
  executionCapability: "synthetic-capability",
  createdAt: "2026-09-22T12:00:00Z",
  expiresAt: "2026-09-22T13:00:00Z",
  questionnaires: [],
};

it("validates only the revision captured when the dialog opened", () => {
  expect(validationRequest("study", candidate.draftRevision)).toEqual({
    path: { studyId: "study" },
    headers: { "If-Match": `"${candidate.draftRevision}"` },
  });
});

it("publishes and retries the exact reviewed candidate, never a new draft", () => {
  const request = publicationRequest("study", candidate);
  expect(request).toEqual({
    path: { studyId: "study" },
    headers: { "If-Match": `"${candidate.draftRevision}"` },
    body: { validationId: candidate.id },
  });
  expect(publicationRequest("study", candidate)).toEqual(request);
  expect(candidate.id).toBe("b0dd46a5-5138-47b4-8e89-682ea91f1d72");
});

it.each([404, 409, 412])(
  "requires reload and review after HTTP %s",
  (status) => {
    expect(
      publicationNeedsReview(new ApiError({ title: "Rejected", status })),
    ).toBe(true);
  },
);

it.each([401, 403, 503])(
  "does not silently replace the candidate after HTTP %s",
  (status) => {
    expect(
      publicationNeedsReview(new ApiError({ title: "Rejected", status })),
    ).toBe(false);
  },
);
