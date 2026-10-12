// This source file is part of the Trove open-source project
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { describe, expect, it } from "vitest";
import {
  consentBlocks,
  newConsentField,
  replaceRange,
  setFieldAttribute,
  renameConsentID,
} from "./document";

const fixture = `---
title: Consent
---

## Participation

Participation is **voluntary**.

<toggle id=agree initial-value=false expected-value=true>
I agree.
<footnote>Read the *whole* document.</footnote>
</toggle>

<select id="contact" initial-value="email" expected-value="*">
Contact method.
<option id=email>Email</option>
<option id=phone>Phone</option>
</select>

<signature id=participant />
`;

describe("consent editor projection", () => {
  it("renames a field without touching wording or another field", () => {
    const blocks = consentBlocks(fixture).filter(
      (block) => block.kind === "control",
    );
    const updated = renameConsentID(fixture, blocks[0].element, "agreement");
    expect(updated).toContain(
      'initial-value=false expected-value=true id="agreement"',
    );
    expect(updated).toContain(
      "<footnote>Read the *whole* document.</footnote>",
    );
    expect(updated).toContain("<signature id=participant />");
    expect(() =>
      renameConsentID(fixture, blocks[0].element, "participant"),
    ).toThrow("unique");
  });

  it("renames an option and both references without changing other options", () => {
    const source = fixture.replace(
      'expected-value="*"',
      'expected-value="email"',
    );
    const parent = consentBlocks(source).find(
      (block) => block.kind === "control" && block.element.name === "select",
    );
    if (parent?.kind !== "control") throw new Error("Missing selection");
    const option = parent.element.children[0];
    const updated = renameConsentID(source, option, "e-mail", parent.element);
    expect(updated).toContain('initial-value="e-mail" expected-value="e-mail"');
    expect(updated).toContain('<option id="e-mail">Email</option>');
    expect(updated).toContain("<option id=phone>Phone</option>");
    expect(() =>
      renameConsentID(source, option, "phone", parent.element),
    ).toThrow("unique");
    expect(() => renameConsentID(source, option, "*", parent.element)).toThrow(
      "reserved",
    );
  });

  it.each([
    "",
    " ",
    " trailing ",
    'id" injected=true',
    "id\\escape",
    "<id>",
    "id\nline",
  ])("rejects invalid IDs without producing altered source: %j", (id) => {
    const block = consentBlocks(fixture).find(
      (item) => item.kind === "control",
    );
    if (block?.kind !== "control") throw new Error("Missing field");
    expect(() => renameConsentID(fixture, block.element, id)).toThrow();
  });
  it("preserves all source bytes and recognizes fields, metadata and footnotes", () => {
    const blocks = consentBlocks(fixture);
    expect(
      blocks.map((block) => fixture.slice(block.start, block.end)).join(""),
    ).toBe(fixture);
    expect(blocks[0].kind).toBe("source");
    const controls = blocks.filter((block) => block.kind === "control");
    expect(controls.map((block) => block.element.name)).toEqual([
      "toggle",
      "select",
      "signature",
    ]);
    expect(controls[0].element.children[0].name).toBe("footnote");
    expect(
      controls[1].element.children.map((child) => child.attributes.id),
    ).toEqual(["email", "phone"]);
  });

  it("changes only the selected field's wording", () => {
    const block = consentBlocks(fixture).find(
      (block) => block.kind === "control",
    );
    if (block?.kind !== "control") throw new Error("Missing fixture field");
    const range = {
      start: block.element.contentStart,
      end: block.element.children[0].start,
    };
    expect(replaceRange(fixture, range, "\nUpdated wording.\n")).toBe(
      fixture.replace("\nI agree.\n", "\nUpdated wording.\n"),
    );
  });

  it("changes a requirement without resetting IDs, initial values, options or footnotes", () => {
    const block = consentBlocks(fixture).find(
      (block) => block.kind === "control",
    );
    if (block?.kind !== "control") throw new Error("Missing fixture field");
    const changed = setFieldAttribute(
      fixture,
      block.element,
      "expected-value",
      "false",
    );
    expect(changed).toBe(
      fixture.replace(" expected-value=true", ' expected-value="false"'),
    );
    expect(
      setFieldAttribute(fixture, block.element, "expected-value", ""),
    ).toBe(fixture.replace(" expected-value=true", ""));
  });

  it.each(["```", "~~~~"])(
    "keeps literal controls inside %s fences as Markdown",
    (fence) => {
      const source = `${fence}\n<toggle id=example>Literal</toggle>\n${fence}\n`;
      expect(consentBlocks(source)).toEqual([
        { kind: "markdown", start: 0, end: source.length },
      ]);
    },
  );

  it.each([
    '<toggle id="agree">Unclosed',
    '<toggle id="agree" expected-value=perhaps>Agree</toggle>',
    '<toggle id="agree" initial-value=yes>Agree</toggle>',
    '<signature id="participant">Hidden wording</signature>',
    "<!-- Unclosed comment",
    '<toggle id="agree" id="again">Repeated</toggle>',
    '<signature id="same" />\n<signature id="same" />',
    '<signature id="a" unsupported="yes" />',
    '<toggle id="a"><script>alert(1)</script></toggle>',
    "---\ntitle: Unclosed",
  ])(
    "rejects unsupported projection without rewriting the source",
    (source) => {
      expect(() => consentBlocks(source)).toThrow();
    },
  );

  it("preserves commented controls without projecting them as active fields", () => {
    const source =
      "<!--\n<toggle id=hidden>Hidden</toggle>\n-->\n<signature id=visible />";
    const blocks = consentBlocks(source);
    expect(
      blocks
        .filter((block) => block.kind === "control")
        .map((block) => block.element.attributes.id),
    ).toEqual(["visible"]);
    expect(
      blocks.map((block) => source.slice(block.start, block.end)).join(""),
    ).toBe(source);
  });

  it("creates distinct field identities on repeated insertions", () => {
    const first = newConsentField("", "toggle");
    const second = newConsentField(first, "toggle");
    expect(first).toContain('id="toggle-1"');
    expect(second).toContain('id="toggle-2"');
    expect(
      consentBlocks(`${first}\n${second}`).filter(
        (block) => block.kind === "control",
      ),
    ).toHaveLength(2);
  });

  it("preserves replacement metacharacters in option identities", () => {
    const source =
      '<select id="contact"><option id="$&">Example</option></select>';
    const block = consentBlocks(source)[0];
    if (block.kind !== "control") throw new Error("Missing fixture field");
    expect(
      setFieldAttribute(source, block.element, "expected-value", "$&"),
    ).toBe(
      '<select id="contact" expected-value="$&"><option id="$&">Example</option></select>',
    );
  });
});
