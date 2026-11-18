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

// Stored once and decoded by the Swift tests as well.
const fixtures = resolve(
  import.meta.dirname,
  "../../../TroveAPI/Tests/Fixtures/MultilingualQuestionnaires",
);
const cases = JSON.parse(
  readFileSync(resolve(fixtures, "cases.json"), "utf8"),
) as FixtureCase[];

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

  it("reports draft tags as written without validating them", () => {
    const translation = (lang: string) => ({
      url: "http://hl7.org/fhir/StructureDefinition/translation",
      extension: [
        { url: "lang", valueCode: lang },
        { url: "content", valueString: "Text" },
      ],
    });
    const draft = JSON.stringify({
      language: "en-us",
      _name: {
        extension: [translation("en-us"), translation("de"), translation("de")],
      },
    });
    expect(questionnaireLanguages(draft)).toEqual({
      base: "en-us",
      translations: ["de", "en-us"],
    });
    expect(questionnaireLanguages("not JSON")).toEqual({ translations: [] });
    expect(questionnaireLanguages("[]")).toEqual({
      base: undefined,
      translations: [],
    });
  });
});
