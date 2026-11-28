// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import type {
  StudyDetailContent,
  StudyDetailData,
  StudyResponse,
  StudyReadinessFacts,
  StudyReadinessContent,
} from "@/lib/api/generated/types.gen";
import { compareCodeUnits } from "@/lib/questionnaireLanguages";
import { readinessFactKeys } from "@/lib/readinessFacts";

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

/** Remove the selected translation from both parts of the same study draft. */
export const withoutLanguage = (
  {
    details,
    readinessFacts,
  }: Pick<StudyResponse, "details" | "readinessFacts">,
  language: string,
) => {
  if (language === details.sourceLanguage) {
    throw new Error("The source language cannot be removed");
  }
  const excludingLanguage = <T>(content: Record<string, T>) =>
    Object.fromEntries(
      Object.entries(content).filter(([key]) => key !== language),
    );
  return {
    details: { ...details, content: excludingLanguage(details.content) },
    readinessFacts: {
      ...readinessFacts,
      content: excludingLanguage(readinessFacts.content),
    },
  };
};

const emptyReadinessFacts = Object.fromEntries(
  readinessFactKeys.map((key) => [key, ""]),
) as Required<StudyReadinessContent>;

/**
 * The stored facts of one language with every fact present. A fact without a stored value is an
 * empty string, so resetting the form to another language clears each field; a field reset to an
 * undefined value keeps the text it showed before.
 */
export const readinessFormFacts = (
  content: StudyReadinessContent | undefined,
): Required<StudyReadinessContent> => ({ ...emptyReadinessFacts, ...content });

export const generalFormValues = (
  study: Pick<StudyResponse, "icon" | "details" | "readinessFacts">,
  language: string,
) => {
  const details = study.details.content[language];
  return {
    facts: readinessFormFacts(study.readinessFacts.content[language]),
    contacts: study.readinessFacts.contacts,
    title: details?.title ?? "",
    icon: study.icon,
    shortTitle: details?.shortTitle ?? null,
    explanationText: details?.explanationText ?? null,
    shortExplanationText: details?.shortExplanationText ?? null,
  };
};

export const withReadinessContent = (
  previous: StudyReadinessFacts,
  language: string,
  facts: StudyReadinessContent,
  contacts: StudyReadinessFacts["contacts"],
): StudyReadinessFacts => ({
  content: { ...previous.content, [language]: facts },
  contacts,
});
