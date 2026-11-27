// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import type { StudyReadinessContent } from "@/lib/api/generated/types.gen";

/** The label of each readiness fact, in the order the General form shows them. */
export const readinessFactLabels: Record<keyof StudyReadinessContent, string> = {
  aims: "Aims",
  population: "Population",
  procedures: "Procedures and collected data",
  burden: "Participant burden",
  retention: "Data retention",
  withdrawal: "Withdrawal",
  concernRoute: "Concern and incidental-finding route",
  coverage: "Responsible coverage",
  coEnrollment: "Co-enrollment policy",
};

/** The readiness facts in the order the General form shows them. */
export const readinessFactKeys = Object.keys(
  readinessFactLabels,
) as ReadonlyArray<keyof StudyReadinessContent>;

export const isReadinessFactKey = (
  key: string,
): key is keyof StudyReadinessContent =>
  Object.hasOwn(readinessFactLabels, key);
