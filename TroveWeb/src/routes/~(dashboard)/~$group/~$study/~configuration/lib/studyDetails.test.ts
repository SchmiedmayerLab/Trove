// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { describe, expect, it } from "vitest";
import type { StudyDetailData } from "@/lib/api/generated/types.gen";
import {
  detailLanguages,
  generalFormValues,
  withReadinessContent,
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
});

describe("readiness form values", () => {
  const study = {
    icon: "heart",
    details,
    readinessFacts: {
      content: { en: { aims: "English aims", procedures: "Survey" } },
      contacts: [
        { name: "Example", role: "Coordinator", email: "contact@example.org" },
      ],
    },
  };
  it("removes only the selected language from details and readiness together", () => {
    const translated = {
      ...study,
      readinessFacts: {
        ...study.readinessFacts,
        content: { ...study.readinessFacts.content, ar: { aims: "هدف" } },
      },
    };
    const patch = withoutLanguage(translated, "ar");
    expect(patch.details.content).toEqual({
      en: details.content.en,
      "zh-Hant": details.content["zh-Hant"],
    });
    expect(patch.readinessFacts).toEqual(study.readinessFacts);
    expect(generalFormValues({ ...study, ...patch }, "ar").facts).toEqual({});
    expect(translated.readinessFacts.content.ar.aims).toBe("هدف");
    expect(() => withoutLanguage(translated, "en")).toThrow();
  });

  it("loads shared contacts and never borrows source facts for a translation", () => {
    expect(generalFormValues(study, "en").facts).toEqual(
      study.readinessFacts.content.en,
    );
    expect(generalFormValues(study, "ar")).toMatchObject({
      facts: {},
      contacts: study.readinessFacts.contacts,
    });
    expect(Object.keys(generalFormValues(study, "ar").facts)).toEqual([]);
  });
  it("updates the edited language and contacts without mutating the loaded snapshot", () => {
    const updated = withReadinessContent(
      study.readinessFacts,
      "ar",
      { aims: "هدف الدراسة" },
      [],
    );
    expect(updated).toEqual({
      content: {
        en: study.readinessFacts.content.en,
        ar: { aims: "هدف الدراسة" },
      },
      contacts: [],
    });
    expect(study.readinessFacts.contacts).toHaveLength(1);
    expect(Object.keys(study.readinessFacts.content)).toEqual(["en"]);
  });
});
