//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { describe, expect, it } from "vitest";
import { dedent } from "./dedent";

describe("dedent", () => {
  it("trims each line and drops the blank ones", () => {
    const result = dedent`
      first line
        second line

      third line
    `;

    expect(result).toBe("first line\nsecond line\nthird line");
  });

  it("interpolates values", () => {
    const subject = "study";

    expect(dedent`a ${subject} here`).toBe("a study here");
  });

  it("renders a missing value as an empty string rather than 'undefined'", () => {
    expect(dedent`before ${undefined} after`).toBe("before  after");
  });

  it("returns an empty string when everything is blank", () => {
    expect(dedent`

    `).toBe("");
  });
});
