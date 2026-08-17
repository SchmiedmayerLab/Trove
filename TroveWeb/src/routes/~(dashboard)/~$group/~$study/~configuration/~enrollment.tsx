//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { createFileRoute } from "@tanstack/react-router";
import { useHotkeys } from "react-hotkeys-hook";
import { NavigationBlocker } from "@/components/interfaces/NavigationBlocker";
import { SaveButton } from "@/components/ui/SaveButton";
import { useUpdateStudyMutation } from "@/lib/queries/study";
import { EnrollmentForm } from "./components/EnrollmentForm";
import { EnrollmentLayout } from "./components/EnrollmentLayout";
import { InvitationCodesCard } from "./components/InvitationCodesCard/InvitationCodesCard";
import { useEnrollmentForm } from "./lib/useEnrollmentForm";

const EnrollmentRouteComponent = () => {
  const params = Route.useParams();
  const { form, studyResponse } = useEnrollmentForm();
  const updateStudy = useUpdateStudyMutation();

  const handleSubmit = form.handleSubmit((data) => {
    updateStudy.mutate(
      {
        path: { studyId: params.study },
        body: {
          enrollmentConditions: data.enrollmentConditions,
          visibility: data.visibility,
        },
      },
      {
        onSuccess: (updatedStudy) => {
          form.reset({
            enrollmentConditions: updatedStudy.enrollmentConditions,
            visibility: updatedStudy.visibility,
          });
        },
      },
    );
  });

  useHotkeys(
    "meta+enter",
    () => void handleSubmit(),
    { enableOnFormTags: ["input", "textarea"] },
    [form],
  );

  const requiresCodes =
    studyResponse?.enrollmentConditions === "requiresInvitationCode";

  return (
    <EnrollmentLayout
      saveButton={
        <SaveButton
          size="sm"
          className="text-sm"
          onClick={handleSubmit}
          isPending={updateStudy.isPending}
          isSuccess={updateStudy.isSuccess}
          isError={updateStudy.isError}
        />
      }
    >
      <div className="flex max-w-7xl flex-col gap-8 p-6">
        <EnrollmentForm form={form} onSubmit={handleSubmit} />
        {requiresCodes && <InvitationCodesCard studyId={params.study} />}
      </div>
      <NavigationBlocker shouldBlock={form.formState.isDirty} />
    </EnrollmentLayout>
  );
};

export const Route = createFileRoute(
  "/(dashboard)/$group/$study/configuration/enrollment",
)({
  component: EnrollmentRouteComponent,
});
