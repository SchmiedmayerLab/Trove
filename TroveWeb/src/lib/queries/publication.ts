// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { ApiError } from "../api/client";
import type {
  PostStudiesByStudyIdPublishData,
  StudyPublicationCandidate,
  ValidateStudyDraftData,
} from "../api/generated/types.gen";
import { draftHeaders } from "./draft";

export const validationRequest = (
  studyId: string,
  draftRevision: string,
): Pick<ValidateStudyDraftData, "path" | "headers"> => ({
  path: { studyId },
  headers: draftHeaders(draftRevision),
});

/** Publication identity comes only from the candidate and revision the researcher reviewed. */
export const publicationRequest = (
  studyId: string,
  draftRevision: string,
  candidate: StudyPublicationCandidate,
): Pick<PostStudiesByStudyIdPublishData, "path" | "headers" | "body"> => ({
  path: { studyId },
  headers: draftHeaders(draftRevision),
  body: { validationId: candidate.id },
});

export const publicationNeedsReview = (error: unknown) =>
  error instanceof ApiError && [404, 409, 412].includes(error.status);
