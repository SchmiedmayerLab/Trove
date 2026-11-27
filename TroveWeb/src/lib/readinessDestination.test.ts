// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { describe, expect, it } from "vitest";
import { readinessDestination } from "./readinessDestination";
import { readinessFactKeys, readinessFactLabels } from "./readinessFacts";

describe("readinessDestination", () => {
  it("links every readiness fact to its field in its language", () => {
    for (const key of readinessFactKeys)
      expect(readinessDestination(`readinessFacts.content.en.${key}`)).toEqual({
        language: "en",
        hash: `readinessFacts.content.en.${key}`,
        label: `Edit ${readinessFactLabels[key].toLowerCase()} (en)`,
      });
    expect(
      readinessDestination("readinessFacts.content.de.concernRoute")?.label,
    ).toBe("Edit concern and incidental-finding route (de)");
  });

  it("links a translation advisory to the language and refuses unknown paths", () => {
    expect(readinessDestination("readinessFacts.content.de")?.label).toBe(
      "Edit translated facts (de)",
    );
    expect(
      readinessDestination("readinessFacts.content.en.unknown"),
    ).toBeUndefined();
    expect(
      readinessDestination("readinessFacts.content.en.toString"),
    ).toBeUndefined();
    expect(
      readinessDestination("readinessFacts.content.not a tag.aims"),
    ).toBeUndefined();
  });

  it("links contacts to their first or named field", () => {
    expect(readinessDestination("readinessFacts.contacts[1].email")).toEqual({
      language: undefined,
      hash: "readinessFacts.contacts[1].email",
      label: "Edit contact 2 email",
    });
    expect(readinessDestination("readinessFacts.contacts")?.label).toBe(
      "Edit responsible contacts",
    );
  });
});
