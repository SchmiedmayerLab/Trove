// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { isLanguageTag } from "./languageTags";

// Shared with the Swift tests of `LanguageTag`.
const cases = JSON.parse(
  readFileSync(
    resolve(
      import.meta.dirname,
      "../../../TroveAPI/Tests/Fixtures/language-tags.json",
    ),
    "utf8",
  ),
) as { accept: string[]; reject: string[] };

describe("language tags", () => {
  it.each(cases.accept)("accepts %s", (tag) => {
    expect(isLanguageTag(tag)).toBe(true);
  });

  it.each(cases.reject)("rejects '%s'", (tag) => {
    expect(isLanguageTag(tag)).toBe(false);
  });
});
