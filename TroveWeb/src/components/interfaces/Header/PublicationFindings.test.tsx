// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type {
  StudyDraftValidation,
  ValidationDiagnostic,
} from "@/lib/api/generated/types.gen";
import { PublicationFindings } from "./PublicationFindings";

const finding = (
  severity: ValidationDiagnostic["severity"],
): ValidationDiagnostic => ({
  severity,
  source: "trove",
  rule: `synthetic-${severity}`,
  path: "Questionnaire.item[0]",
  componentId: "component-1",
  message: `Synthetic ${severity}`,
});

const report = (
  status: StudyDraftValidation["status"],
  candidate: boolean,
): StudyDraftValidation => ({
  draftRevision: "revision",
  status,
  blockers: status === "valid" ? [] : [finding("error")],
  advisories: [finding("warning")],
  routes: [],
  questionnaires: [],
  candidate:
    candidate ?
      {
        id: "candidate",
        publicationRevision: 1,
        bundleSha256: "0".repeat(64),
        validatorIdentity: "synthetic",
        contractRevision: "synthetic",
        executionCapability: "synthetic",
        createdAt: "2026-09-22T12:00:00Z",
        expiresAt: "2026-09-22T13:00:00Z",
      }
    : undefined,
});

const render = (value: StudyDraftValidation) =>
  renderToStaticMarkup(
    <PublicationFindings report={value} componentName={() => "Wellbeing"} />,
  );

describe("PublicationFindings", () => {
  it("lists blockers once, as the focus target described by the overall result", () => {
    const markup = render(report("invalid", false));
    expect(markup.match(/>Blockers</g)).toHaveLength(1);
    const heading =
      /<h3 id="([^"]+)" tabindex="-1" aria-describedby="([^"]+)"[^>]*>Blockers<\/h3>/.exec(
        markup,
      );
    expect(heading).not.toBeNull();
    expect(markup).toContain(`<p id="${heading?.[2]}">Invalid.`);
  });

  it("identifies unavailable routes with the same profile from the validation report alone", () => {
    const value = report("valid", true);
    value.advisories = [];
    value.routes = ["one", "two"].map((id, index) => ({
      index,
      profile: "weight",
      sourceKind: "server-worker",
      providerRegistrationId: "registration-" + id,
      sourceTypeIdentifier: "measurement-" + id,
      availability: "unavailable",
      requirement: "optional",
    }));
    const markup = render(value);
    for (const id of ["one", "two"]) {
      expect(markup).toMatch(
        new RegExp(
          `<p[^>]*>Unavailable optional collection route:[^<]*weight[^<]*<code>registration-${id}</code>[^<]*<code>measurement-${id}</code></p>`,
        ),
      );
    }
  });

  it("does not list available routes", () => {
    const value = report("valid", true);
    value.advisories = [];
    value.routes = [
      {
        index: 0,
        profile: "heart-rate",
        sourceKind: "participant-app",
        availability: "available",
        requirement: "required",
      },
    ];
    expect(render(value)).not.toContain("heart-rate");
  });

  it("does not repeat the overall result under advisories", () => {
    const markup = render(report("valid", true));
    expect(markup).not.toContain(">Blockers<");
    expect(markup.match(/>Advisories</g)).toHaveLength(1);
    expect(markup).not.toContain(
      "Valid. No errors and no skipped checks were reported.",
    );
  });
});
