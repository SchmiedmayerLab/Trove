// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { describe, expect, it } from "vitest";
import type { StudyDetailData } from "@/lib/api/generated/types.gen";
import { compareCodeUnits } from "@/lib/questionnaireLanguages";
import {
  detailLanguages,
  withDetailContent,
  withSourceLanguage,
  withoutLanguage,
} from "./studyDetails";

const details: StudyDetailData = {
  sourceLanguage: "en",
  content: {
    "zh-Hant": { title: "研究" },
    en: { title: "Study" },
    ar: { title: "دراسة" },
  },
};

describe("study details languages", () => {
  it("lists the source language first", () => {
    expect(detailLanguages(details)).toEqual(["en", "ar", "zh-Hant"]);
  });

  it("adds a translation without changing the source language", () => {
    expect(withDetailContent(details, "pt-BR", { title: "Estudo" })).toEqual({
      sourceLanguage: "en",
      content: { ...details.content, "pt-BR": { title: "Estudo" } },
    });
  });

  it("changes the source language only to a language with details", () => {
    expect(withSourceLanguage(details, "ar").sourceLanguage).toBe("ar");
    expect(() => withSourceLanguage(details, "de")).toThrow();
  });

  it("removes translations but keeps the source language", () => {
    expect(
      Object.keys(withoutLanguage(details, "ar").content).sort(
        compareCodeUnits,
      ),
    ).toEqual(["en", "zh-Hant"]);
    expect(() => withoutLanguage(details, "en")).toThrow();
  });
});
