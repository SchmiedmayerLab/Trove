// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { draftHeaders } from "./draft";
import { ApiError } from "../api/client";
import type {
  PostStudiesByStudyIdPublishData,
  StudyDraftValidation,
  ValidateStudyDraftData,
} from "../api/generated/types.gen";

export const validationRequest = (
  studyId: string,
  draftRevision: string,
): Pick<ValidateStudyDraftData, "path" | "headers"> => ({
  path: { studyId },
  headers: draftHeaders(draftRevision),
});

/** Publication identity comes only from the receipt the researcher reviewed. */
export const publicationRequest = (
  studyId: string,
  candidate: StudyDraftValidation,
): Pick<PostStudiesByStudyIdPublishData, "path" | "headers" | "body"> => ({
  path: { studyId },
  headers: draftHeaders(candidate.draftRevision),
  body: { validationId: candidate.id },
});

export const publicationNeedsReview = (error: unknown) =>
  error instanceof ApiError && [404, 409, 412].includes(error.status);
