// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { ValidationDiagnostic } from "@/lib/api/generated/types.gen";
import { ValidationDiagnostics } from "./ValidationDiagnostics";

const diagnostics: ValidationDiagnostic[] = [
  {
    severity: "error",
    source: "fhir",
    rule: "Inv_Failed",
    path: "Questionnaire.item[0].text.extension[0]",
    language: "de",
    componentId: "component-1",
    message: "Constraint failed: qg-translation-1",
  },
  {
    severity: "warning",
    source: "trove",
    rule: "base-language-region",
    path: "Questionnaire.language",
    message: "The participant bundle requires a base language with a region.",
    nextAction: "Set Questionnaire.language to a language with a region.",
  },
];

describe("ValidationDiagnostics", () => {
  const markup = renderToStaticMarkup(
    <ValidationDiagnostics
      title="Blockers"
      status="invalid"
      diagnostics={diagnostics}
      componentName={(id) => (id === "component-1" ? "Wellbeing" : undefined)}
      locate={(diagnostic) =>
        diagnostic.path.includes("item") ? () => undefined : undefined
      }
    />,
  );

  it("lists each finding with its severity in text and hides decorative icons", () => {
    expect(markup).toContain("<ul");
    expect(markup.match(/<li/g)).toHaveLength(2);
    expect(markup).toContain("Error:");
    expect(markup).toContain("Warning:");
    expect(markup.match(/aria-hidden="true"/g)).toHaveLength(2);
  });

  it("names the rule, element, language, component and next action", () => {
    expect(markup).toContain("Inv_Failed");
    expect(markup).toContain("Questionnaire.item[0].text.extension[0]");
    expect(markup).toContain("<dd>de</dd>");
    expect(markup).toContain("Wellbeing");
    expect(markup).toContain(
      "Set Questionnaire.language to a language with a region.",
    );
    expect(markup).toContain("Invalid. Resolve the errors before publishing.");
  });

  it("offers to show only findings whose element can be found, without live regions", () => {
    expect(markup.match(/Show item in JSON/g)).toHaveLength(1);
    expect(markup).not.toContain("aria-live");
    expect(markup).not.toContain('role="alert"');
    expect(markup).toMatch(/<section aria-labelledby="[^"]+"/);
  });

  it("states that an unavailable validator establishes nothing", () => {
    const unavailable = renderToStaticMarkup(
      <ValidationDiagnostics
        title="Validation result"
        status="unavailable"
        diagnostics={[]}
      />,
    );
    expect(unavailable).toContain(
      "Not checked. The validator could not be reached; validate again later.",
    );
    expect(unavailable).not.toContain("<ul");
  });
});
