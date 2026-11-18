// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

const translationUrl = "http://hl7.org/fhir/StructureDefinition/translation";

export interface QuestionnaireLanguages {
  /** `Questionnaire.language`, when the text is a JSON object that names one. */
  base?: string;
  /** Distinct translation languages, sorted. */
  translations: string[];
}

/** Orders by UTF-16 code units, as the server orders the ASCII tags it reports. */
export const compareCodeUnits = (left: string, right: string): number => {
  if (left < right) return -1;
  return left > right ? 1 : 0;
};

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

/**
 * Reads the languages a FHIR Questionnaire's JSON names: its base `Questionnaire.language` and the
 * `lang` of every standard `translation` extension, as written; `undefined` when the text is not JSON.
 * This previews unsaved text the way the server reads a saved draft; it neither validates nor rewrites it.
 */
export const questionnaireLanguages = (
  text: string,
): QuestionnaireLanguages | undefined => {
  let resource: unknown;
  try {
    resource = JSON.parse(text);
  } catch {
    return undefined;
  }
  const translations = new Set<string>();
  const collect = (value: unknown, depth: number) => {
    if (depth > 64) return;
    if (Array.isArray(value)) {
      for (const element of value) collect(element, depth + 1);
    } else if (isRecord(value)) {
      if (value.url === translationUrl && Array.isArray(value.extension)) {
        for (const part of value.extension) {
          if (
            isRecord(part) &&
            part.url === "lang" &&
            typeof part.valueCode === "string"
          ) {
            translations.add(part.valueCode);
          }
        }
      }
      for (const member of Object.values(value)) collect(member, depth + 1);
    }
  };
  collect(resource, 0);
  const base =
    isRecord(resource) && typeof resource.language === "string" ?
      resource.language
    : undefined;
  return { base, translations: [...translations].sort(compareCodeUnits) };
};
