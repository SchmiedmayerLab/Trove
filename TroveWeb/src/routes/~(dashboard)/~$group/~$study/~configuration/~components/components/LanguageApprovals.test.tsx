// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { QuestionnaireComponentResponse } from "@/lib/api/generated/types.gen";
import { LanguageApprovals } from "./LanguageApprovals";

const session = vi.hoisted(() => ({ role: "researcher", study: "study" }));
vi.mock("@/lib/auth/AuthProvider", () => ({
  useAuth: () => ({ user: { groupMemberships: { Lab: session.role } } }),
}));
vi.mock("@/lib/queries/group", () => ({
  groupRetrieveQueryOptions: () => ({ data: { name: "Lab", id: "group" } }),
}));
vi.mock("@/lib/queries/study", () => ({
  studyListQueryOptions: () => ({ data: [{ id: session.study }] }),
}));
vi.mock("@tanstack/react-query", () => ({
  useQuery: (options: unknown) => options,
}));
vi.mock("@/lib/queries/component", () => ({
  useApproveLanguage: () => ({}),
  useRevokeLanguage: () => ({}),
}));

const component: QuestionnaireComponentResponse = {
  id: "instrument",
  name: "Survey",
  data: { questionnaire: "{}" },
  sha256: "a".repeat(64),
  language: "en",
  translationLanguages: ["de"],
  administrationLanguages: ["en", "de"],
  languageApprovals: [],
};
const render = (value = component, dirty = false) =>
  renderToStaticMarkup(
    <LanguageApprovals
      component={value}
      groupId="group"
      studyId="study"
      dirty={dirty}
    />,
  );
const approval = {
  id: "approval",
  componentId: "instrument",
  sha256: component.sha256,
  language: "de",
  approvedAt: "2026-11-21T12:00:00Z",
};

describe("saved instrument approvals", () => {
  beforeEach(() => {
    session.role = "admin";
    session.study = "study";
  });
  it("shows only approvals in force for this digest, instrument and language", () => {
    const html = render({ ...component, languageApprovals: [approval] });
    expect(html).toContain("Revoke approval for de");
    expect(html).toContain("Approve en");
    for (const stale of [
      { ...approval, sha256: "b".repeat(64) },
      { ...approval, componentId: "other" },
      { ...approval, revokedAt: approval.approvedAt },
    ]) {
      expect(render({ ...component, languageApprovals: [stale] })).toContain(
        "Approve de",
      );
    }
  });
  it("keeps approval status visible to researchers without mutation controls", () => {
    session.role = "researcher";
    const html = render({ ...component, languageApprovals: [approval] });
    expect(html).toContain("Approved");
    expect(html).not.toContain("<button");
  });
  it("requires the study to belong to the administrator's group", () => {
    session.study = "other";
    expect(render()).not.toContain("<button");
  });
  it("disables both mutations while the displayed draft is dirty", () => {
    expect(
      render({ ...component, languageApprovals: [approval] }, true).match(
        /disabled=""/g,
      ),
    ).toHaveLength(2);
  });
});
