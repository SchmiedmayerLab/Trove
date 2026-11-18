//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import {
  ConfirmDeleteDialog,
  useOpenState,
} from "@schmiedmayerlab/grove-design-system";
import { useQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";
import { useHotkeys } from "react-hotkeys-hook";
import { NavigationBlocker } from "@/components/interfaces/NavigationBlocker";
import { PhonePreview } from "@/components/interfaces/PhonePreview";
import { Card } from "@/components/ui/Card";
import { SaveButton } from "@/components/ui/SaveButton";
import type {
  StudyDetailContent,
  StudyDetailData,
} from "@/lib/api/generated/types.gen";
import { draftHeaders } from "@/lib/queries/draft";
import {
  studyResponseQueryOptions,
  useUpdateStudyMutation,
} from "@/lib/queries/study";
import { DetailLanguageBar } from "./components/DetailLanguageBar";
import { GeneralForm } from "./components/GeneralForm";
import { GeneralLayout } from "./components/GeneralLayout";
import { GeneralPreview } from "./components/GeneralPreview";
import {
  detailLanguages,
  withDetailContent,
  withSourceLanguage,
  withoutLanguage,
} from "./lib/studyDetails";
import { useGeneralForm } from "./lib/useGeneralForm";

const GeneralRouteComponent = () => {
  const params = Route.useParams();
  const { data: study } = useQuery(
    studyResponseQueryOptions({ studyId: params.study }),
  );
  const [selectedLanguage, setSelectedLanguage] = useState<string>();
  const language = selectedLanguage ?? study?.details.sourceLanguage ?? "";
  const { form, getStudySnapshot, getDraftHeaders } = useGeneralForm(language);
  const updateStudy = useUpdateStudyMutation();
  const removeDialog = useOpenState();

  const [highlightedField, setHighlightedField] = useState<
    string | undefined
  >();

  const languages =
    study ? [...new Set([...detailLanguages(study.details), language])] : [];

  const saveDetails = (details: StudyDetailData, onSuccess?: () => void) => {
    const snapshot = getStudySnapshot();
    updateStudy.mutate(
      {
        path: { studyId: params.study },
        headers: draftHeaders(snapshot.draftRevision),
        body: { details },
      },
      { onSuccess },
    );
  };

  const handleSubmit = form.handleSubmit((data) => {
    const { icon, ...textFields } = data;
    const languageContent: StudyDetailContent = {
      title: textFields.title,
      ...(textFields.shortTitle != null && {
        shortTitle: textFields.shortTitle,
      }),
      ...(textFields.explanationText != null && {
        explanationText: textFields.explanationText,
      }),
      ...(textFields.shortExplanationText != null && {
        shortExplanationText: textFields.shortExplanationText,
      }),
    };

    updateStudy.mutate(
      {
        path: { studyId: params.study },
        headers: getDraftHeaders(),
        body: {
          ...(icon != null && { icon }),
          details: withDetailContent(
            getStudySnapshot().details,
            language,
            languageContent,
          ),
        },
      },
      {
        onSuccess: (response) => {
          const details = response.details.content[language];
          form.reset({
            icon: response.icon,
            title: details?.title ?? "",
            shortTitle: details?.shortTitle ?? null,
            explanationText: details?.explanationText ?? null,
            shortExplanationText: details?.shortExplanationText ?? null,
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
    <GeneralLayout
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
        <Card>
          {study && (
            <div className="pt-6">
              <DetailLanguageBar
                languages={languages}
                sourceLanguage={study.details.sourceLanguage}
                language={language}
                isSaved={study.details.content[language] !== undefined}
                disabled={form.formState.isDirty || updateStudy.isPending}
                onSelect={setSelectedLanguage}
                onMakeSource={() =>
                  saveDetails(
                    withSourceLanguage(getStudySnapshot().details, language),
                  )
                }
                onRemove={removeDialog.open}
              />
            </div>
          )}
          <GeneralForm
            form={form}
            language={language}
            onSubmit={handleSubmit}
            onFieldFocus={setHighlightedField}
            onFieldBlur={() => setHighlightedField(undefined)}
          />
        </Card>
        <PhonePreview>
          <GeneralPreview form={form} highlightedField={highlightedField} />
        </PhonePreview>
      </div>
      <ConfirmDeleteDialog
        open={removeDialog.isOpen}
        onOpenChange={removeDialog.setIsOpen}
        entityName="language"
        itemName={language}
        onDelete={() =>
          saveDetails(
            withoutLanguage(getStudySnapshot().details, language),
            () => {
              removeDialog.close();
              setSelectedLanguage(undefined);
            },
          )
        }
      />
      <NavigationBlocker shouldBlock={form.formState.isDirty} />
    </GeneralLayout>
  );
};

export const Route = createFileRoute(
  "/(dashboard)/$group/$study/configuration/general",
)({
  component: GeneralRouteComponent,
});
