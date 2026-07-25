//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { createFileRoute } from "@tanstack/react-router";
import { useHotkeys } from "react-hotkeys-hook";
import { NavigationBlocker } from "@/components/interfaces/NavigationBlocker";
import { Card } from "@/components/ui/Card";
import { SaveButton } from "@/components/ui/SaveButton";
import type { ConsentContent } from "@/lib/api/generated/types.gen";
import { useLocale } from "@/lib/locale";
import { useUpdateStudyMutation } from "@/lib/queries/study";
import { ConsentForm } from "./components/ConsentForm";
import { ConsentLayout } from "./components/ConsentLayout";
import { useConsentForm } from "./lib/useConsentForm";

const ConsentRouteComponent = () => {
  const params = Route.useParams();
  const { locale } = useLocale();
  const { form, studyResponse } = useConsentForm(locale);
  const updateStudy = useUpdateStudyMutation();

  const handleSubmit = form.handleSubmit((data) => {
    const localeContent: ConsentContent = {
      title: data.title,
      content: data.content,
    };

    updateStudy.mutate(
      {
        path: { studyId: params.study },
        body: {
          consent: { ...studyResponse?.consent, [locale]: localeContent },
        },
      },
      {
        onSuccess: (response) => {
          const updated = response.consent[locale];
          form.reset({
            title: updated.title,
            content: updated.content,
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

  return (
    <ConsentLayout
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
      <div className="flex max-w-7xl gap-8 p-6">
        <Card className="flex-1">
          <ConsentForm form={form} locale={locale} onSubmit={handleSubmit} />
        </Card>
      </div>
      <NavigationBlocker shouldBlock={form.formState.isDirty} />
    </ConsentLayout>
  );
};

export const Route = createFileRoute(
  "/(dashboard)/$group/$study/configuration/consent",
)({
  component: ConsentRouteComponent,
});
