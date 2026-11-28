// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import {
  compareCodeUnits,
  questionnaireLanguages,
} from "./questionnaireLanguages";

interface FixtureCase {
  file: string;
  language: string;
  translationLanguages: string[];
}

interface DraftCase {
  name: string;
  text: string;
  isJSON: boolean;
  language?: string;
  translationLanguages: string[];
}

// Stored once and read by the Swift tests as well.
const fixtures = resolve(
  import.meta.dirname,
  "../../../TroveAPI/Tests/Fixtures/MultilingualQuestionnaires",
);
const read = (file: string): unknown =>
  JSON.parse(readFileSync(resolve(fixtures, file), "utf8"));
const cases = read("cases.json") as FixtureCase[];
const drafts = read("draft-language-cases.json") as DraftCase[];

describe("questionnaire languages", () => {
  it.each(cases.map((fixture) => [fixture.file, fixture] as const))(
    "reads the base and translation languages of %s",
    (file, fixture) => {
      const text = readFileSync(resolve(fixtures, file), "utf8");
      expect(questionnaireLanguages(text)).toEqual({
        base: fixture.language,
        translations: fixture.translationLanguages,
      });
    },
  );

  it("covers language-only, script, region and right-to-left tags", () => {
    expect(
      cases
        .flatMap((fixture) => fixture.translationLanguages)
        .sort(compareCodeUnits),
    ).toEqual(["ar", "de", "pt-BR", "zh-Hant"]);
  });

  it.each(drafts.map((draft) => [draft.name, draft] as const))(
    "reads draft text as the server does: %s",
    (_, draft) => {
      expect(questionnaireLanguages(draft.text)).toEqual(
        draft.isJSON ?
          { base: draft.language, translations: draft.translationLanguages }
        : undefined,
      );
    },
  );
});
