// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import {
  questionnaireFormSchema,
  questionnaireFormValues,
  questionnaireInput,
  shownValidation,
} from "./questionnaireForm";

const fixtures = resolve(
  import.meta.dirname,
  "../../../../../../../../TroveAPI/Tests/Fixtures/MultilingualQuestionnaires",
);
const cases = JSON.parse(
  readFileSync(resolve(fixtures, "cases.json"), "utf8"),
) as Array<{
  file: string;
  language: string;
  translationLanguages: string[];
}>;

describe("questionnaire form", () => {
  it.each(cases.map((fixture) => [fixture.file, fixture] as const))(
    "saves %s as one resource with its exact text",
    (file, fixture) => {
      const text = readFileSync(resolve(fixtures, file), "utf8");
      const values = questionnaireFormValues({
        id: "00000000-0000-4000-8000-000000000000",
        name: "Weekly check-in",
        data: { questionnaire: text },
        language: fixture.language,
        translationLanguages: fixture.translationLanguages,
      });
      expect(questionnaireFormSchema.safeParse(values).success).toBe(true);
      expect(questionnaireInput(values)).toEqual({
        name: "Weekly check-in",
        data: { questionnaire: text },
      });
    },
  );

  it("rejects text that is not JSON", () => {
    expect(
      questionnaireFormSchema.safeParse({ name: "Draft", questionnaire: "{" })
        .success,
    ).toBe(false);
  });
});

describe("shownValidation", () => {
  const result = { draftRevision: "revision-1", status: "valid" };

  it("shows a result only for its saved revision without unsaved changes", () => {
    expect(shownValidation(result, "revision-1", false)).toBe(result);
    expect(shownValidation(result, "revision-1", true)).toBeUndefined();
    expect(shownValidation(result, "revision-2", false)).toBeUndefined();
    expect(shownValidation(result, undefined, false)).toBeUndefined();
    expect(shownValidation(undefined, "revision-1", false)).toBeUndefined();
  });
});
