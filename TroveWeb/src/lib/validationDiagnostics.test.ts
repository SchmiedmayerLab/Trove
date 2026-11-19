// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { describe, expect, it } from "vitest";
import { itemLinkId, linkIdRange } from "./validationDiagnostics";

const text = JSON.stringify(
  {
    resourceType: "Questionnaire",
    item: [
      { linkId: "intro", type: "display" },
      {
        linkId: "group.1",
        type: "group",
        item: [{ linkId: 'say "hi"', type: "string" }],
      },
    ],
  },
  null,
  2,
);

describe("itemLinkId", () => {
  it("names the innermost item of a FHIRPath", () => {
    expect(itemLinkId(text, "Questionnaire.item[1]")).toBe("group.1");
    expect(itemLinkId(text, "Questionnaire.item[1].item[0].text")).toBe(
      'say "hi"',
    );
    expect(
      itemLinkId(text, "Questionnaire.item[1].item[0].text.extension[0]"),
    ).toBe('say "hi"');
  });

  it("names nothing outside items or for text that is not JSON", () => {
    expect(itemLinkId(text, "Questionnaire.language")).toBeUndefined();
    expect(itemLinkId(text, "Questionnaire.item[7]")).toBeUndefined();
    expect(itemLinkId(text, "QuestionnaireResponse.item[0]")).toBeUndefined();
    expect(itemLinkId("{", "Questionnaire.item[0]")).toBeUndefined();
    expect(itemLinkId(text, "")).toBeUndefined();
  });
});

describe("linkIdRange", () => {
  it("selects the exact linkId member, escaping its text", () => {
    const range = linkIdRange(text, 'say "hi"');
    expect(range).toBeDefined();
    const [start, end] = range ?? [0, 0];
    expect(text.slice(start, end)).toBe('"linkId": "say \\"hi\\""');
    const dotted = linkIdRange(text, "group.1") ?? [0, 0];
    expect(text.slice(...dotted)).toBe('"linkId": "group.1"');
    expect(linkIdRange(text, "groupX1")).toBeUndefined();
  });

  it("ignores member-like text inside a string value", () => {
    const tricky =
      '{"text": "\\"linkId\\": \\"x\\"", "item": [{"linkId": "x"}]}';
    const [start, end] = linkIdRange(tricky, "x") ?? [0, 0];
    expect(start).toBe(tricky.indexOf('{"linkId"') + 1);
    expect(tricky.slice(start, end)).toBe('"linkId": "x"');
  });
});
