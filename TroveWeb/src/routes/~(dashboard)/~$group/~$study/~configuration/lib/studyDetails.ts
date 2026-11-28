// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import type {
  StudyDetailContent,
  StudyDetailData,
} from "@/lib/api/generated/types.gen";
import { compareCodeUnits } from "@/lib/questionnaireLanguages";

/** The source language first, then every other language with details, sorted. */
export const detailLanguages = (details: StudyDetailData): string[] => [
  details.sourceLanguage,
  ...Object.keys(details.content)
    .filter((language) => language !== details.sourceLanguage)
    .sort(compareCodeUnits),
];

export const withDetailContent = (
  details: StudyDetailData,
  language: string,
  content: StudyDetailContent,
): StudyDetailData => ({
  sourceLanguage: details.sourceLanguage,
  content: { ...details.content, [language]: content },
});

/** Names a language that already has details as the one they were written in. */
export const withSourceLanguage = (
  details: StudyDetailData,
  language: string,
): StudyDetailData => {
  if (!details.content[language]) {
    throw new Error("The source language needs saved details");
  }
  return { sourceLanguage: language, content: details.content };
};

/** Removes a translation; the source language stays. */
export const withoutLanguage = (
  details: StudyDetailData,
  language: string,
): StudyDetailData => {
  if (language === details.sourceLanguage) {
    throw new Error("The source language cannot be removed");
  }
  return {
    sourceLanguage: details.sourceLanguage,
    content: Object.fromEntries(
      Object.entries(details.content).filter(([key]) => key !== language),
    ),
  };
};
