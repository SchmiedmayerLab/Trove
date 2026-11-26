// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { Button } from "@schmiedmayerlab/grove-design-system";
import { useQuery } from "@tanstack/react-query";
import type { QuestionnaireComponentResponse } from "@/lib/api/generated/types.gen";
import { useAuth } from "@/lib/auth/AuthProvider";
import { useApproveLanguage, useRevokeLanguage } from "@/lib/queries/component";
import { groupRetrieveQueryOptions } from "@/lib/queries/group";
import { studyListQueryOptions } from "@/lib/queries/study";

export const LanguageApprovals = ({
  studyId,
  groupId,
  component,
  dirty,
}: {
  studyId: string;
  groupId: string;
  component: QuestionnaireComponentResponse;
  dirty: boolean;
}) => {
  const { user } = useAuth();
  const { data: group } = useQuery(groupRetrieveQueryOptions({ groupId }));
  const { data: studies } = useQuery(studyListQueryOptions({ groupId }));
  const administrator =
    group?.id === groupId &&
    user?.groupMemberships[group.name] === "admin" &&
    studies?.some((study) => study.id === studyId);
  const approve = useApproveLanguage();
  const revoke = useRevokeLanguage();
  const path = { studyId, componentId: component.id };
  const active = component.languageApprovals.filter(
    (a) =>
      a.componentId === component.id &&
      a.sha256 === component.sha256 &&
      !a.revokedAt,
  );
  const languages = [
    ...new Set([
      ...component.administrationLanguages,
      ...active.map((a) => a.language),
    ]),
  ];
  const pending = approve.isPending || revoke.isPending;
  return (
    <section className="grid gap-3 px-6 py-4">
      <h2>Saved language approvals</h2>
      <p>
        Review the saved questionnaire in each admitted language. Editing the
        resource requires approval of its new SHA-256 digest.
      </p>
      <p className="break-all">
        Saved SHA-256 <code>{component.sha256}</code>
      </p>
      {dirty && <p>Save your edits before changing approvals.</p>}
      {languages.map((language) => {
        const approval = active.find((a) => a.language === language);
        const canApprove =
          component.language === language ||
          component.translationLanguages.includes(language);
        return (
          <div
            key={language}
            tabIndex={-1}
            id={`approval-${language}`}
            className="flex items-center gap-3"
          >
            <span>
              {language}: {approval ? "Approved" : "Awaiting approval"}
            </span>
            {administrator && (approval !== undefined || canApprove) && (
              <Button
                type="button"
                size="sm"
                variant="outline"
                disabled={dirty || pending}
                onClick={() => {
                  if (approval)
                    revoke.mutate({
                      path: { ...path, approvalId: approval.id },
                    });
                  else
                    approve.mutate({
                      path,
                      body: { sha256: component.sha256, language },
                    });
                }}
              >
                {approval ? "Revoke approval for" : "Approve"} {language}
              </Button>
            )}
          </div>
        );
      })}
    </section>
  );
};
