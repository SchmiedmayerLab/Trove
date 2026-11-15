// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { ApiError } from "../api/client";
import { getStudyData } from "../api/generated/sdk.gen";
import type { StudyDataVersions } from "../api/generated/types.gen";
import { zStudyDataPage } from "../api/generated/zod.gen";

/** FHIR contract ceiling; independent of the CSV download fallback capacity. */
export const studyBundleByteLimit = 64 * 1024 * 1024;
const studyBundleBase64Limit = 4 * Math.ceil(studyBundleByteLimit / 3);

/** One explicit disclosure. Do not put clinical pages in the shared query cache. */
export const loadStudyData = async (
  studyId: string,
  versions: StudyDataVersions,
  limit: number,
  before: string | undefined,
  signal: AbortSignal,
) => {
  const { data } = await getStudyData({
    path: { studyId },
    query: { versions, limit, before },
    signal,
    cache: "no-store",
    throwOnError: true,
  });
  signal.throwIfAborted();
  const page = zStudyDataPage.parse(data);
  if (
    page.studyId.toLowerCase() !== studyId.toLowerCase() ||
    page.versions !== versions ||
    page.records.length > limit ||
    page.records.reduce((count, record) => count + record.outputs.length, 0) >
      1024
  ) {
    throw new Error("Invalid study data response");
  }
  return page;
};

/** Preserve FHIR decimal tokens and UTF-8 bytes; never parse and reserialize. */
export const studyBundleBytes = (encoded: string): Uint8Array<ArrayBuffer> => {
  if (!encoded || encoded.length > studyBundleBase64Limit) {
    throw new Error("Invalid study Bundle");
  }
  const binary = atob(encoded);
  if (binary.length > studyBundleByteLimit) {
    throw new Error("Invalid study Bundle");
  }
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index++) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
};

export const studyDataErrorMessage = (error: unknown): string => {
  if (error instanceof ApiError) {
    switch (error.status) {
      case 401:
        return "Your session is no longer authorized. Sign in again.";
      case 403:
        return "You do not have permission to read this study's data. Contact your group administrator.";
      case 400:
      case 409:
        return "The page is no longer available. Load the first page again.";
      case 503:
        return "Data is temporarily unavailable or this page is too large. Try fewer records per page.";
    }
  }
  // Never render raw transport errors or clinical response bodies.
  return "Unable to load study data. Try again.";
};
