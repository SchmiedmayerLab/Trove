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
import { createFileRoute, useLocation } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { useHotkeys } from "react-hotkeys-hook";
import { NavigationBlocker } from "@/components/interfaces/NavigationBlocker";
import { PhonePreview } from "@/components/interfaces/PhonePreview";
import { Card } from "@/components/ui/Card";
import { SaveButton } from "@/components/ui/SaveButton";
import type {
  StudyDetailContent,
  StudyPatchInput,
} from "@/lib/api/generated/types.gen";
import { isLanguageTag } from "@/lib/languageTags";
import { draftHeaders } from "@/lib/queries/draft";
import { useUpdateStudyMutation } from "@/lib/queries/study";
import { DetailLanguageBar } from "./components/DetailLanguageBar";
import { GeneralForm } from "./components/GeneralForm";
import { GeneralLayout } from "./components/GeneralLayout";
import { GeneralPreview } from "./components/GeneralPreview";
import {
  detailLanguages,
  generalFormValues,
  withReadinessContent,
  withDetailContent,
  withSourceLanguage,
  withoutLanguage,
} from "./lib/studyDetails";
import { useGeneralForm } from "./lib/useGeneralForm";

const GeneralRouteComponent = () => {
  const params = Route.useParams();
  const { language: selectedLanguage } = Route.useSearch();
  const navigate = Route.useNavigate();
  const setSelectedLanguage = (language?: string) =>
    void navigate({ search: { language }, replace: true });
  const hash = useLocation({ select: (location) => location.hash });
  const { form, study, language, getStudySnapshot, getDraftHeaders } =
    useGeneralForm(selectedLanguage);
  const loaded = !!study;
  useEffect(() => {
    if (!loaded || !hash) return;
    const frame = requestAnimationFrame(() =>
      document.getElementById(hash)?.focus(),
    );
    return () => cancelAnimationFrame(frame);
  }, [loaded, hash]);
  const updateStudy = useUpdateStudyMutation();
  const removeDialog = useOpenState();

  const [highlightedField, setHighlightedField] = useState<
    string | undefined
  >();

  const languages =
    study ? [...new Set([...detailLanguages(study.details), language])] : [];

  const saveDetails = (
    body: Pick<StudyPatchInput, "details" | "readinessFacts">,
    onSuccess?: () => void,
  ) => {
    const snapshot = getStudySnapshot();
    updateStudy.mutate(
      {
        path: { studyId: params.study },
        headers: draftHeaders(snapshot.draftRevision),
        body,
      },
      { onSuccess },
    );
  };

  const handleSubmit = form.handleSubmit((data) => {
    if (updateStudy.isPending) return;
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
          readinessFacts: withReadinessContent(
            getStudySnapshot().readinessFacts,
            language,
            data.facts,
            data.contacts,
          ),
          ...(icon != null && { icon }),
          details: withDetailContent(
            getStudySnapshot().details,
            language,
            languageContent,
          ),
        },
      },
      {
        onSuccess: (response) =>
          form.reset(generalFormValues(response, language)),
      },
    );
  });

  useHotkeys(
    ["meta+enter", "ctrl+enter"],
    () => void handleSubmit(),
    { preventDefault: true, enableOnFormTags: ["input", "textarea"] },
    [handleSubmit],
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
                  saveDetails({
                    details: withSourceLanguage(
                      getStudySnapshot().details,
                      language,
                    ),
                  })
                }
                onRemove={removeDialog.open}
              />
            </div>
          )}
          <fieldset className="min-w-0" disabled={updateStudy.isPending}>
            <GeneralForm
              form={form}
              language={language}
              onSubmit={handleSubmit}
              sourceLanguage={study?.details.sourceLanguage}
              onFieldFocus={setHighlightedField}
              onFieldBlur={() => setHighlightedField(undefined)}
            />
          </fieldset>
        </Card>
        <PhonePreview>
          <GeneralPreview
            form={form}
            language={language}
            highlightedField={highlightedField}
          />
        </PhonePreview>
      </div>
      <ConfirmDeleteDialog
        open={removeDialog.isOpen}
        onOpenChange={removeDialog.setIsOpen}
        isPending={updateStudy.isPending}
        entityName="language"
        itemName={language}
        onDelete={() =>
          saveDetails(withoutLanguage(getStudySnapshot(), language), () => {
            removeDialog.close();
            setSelectedLanguage();
          })
        }
      />
      <NavigationBlocker shouldBlock={form.formState.isDirty} />
    </GeneralLayout>
  );
};

export const Route = createFileRoute(
  "/(dashboard)/$group/$study/configuration/general",
)({
  validateSearch: (search: Record<string, unknown>): { language?: string } =>
    typeof search.language === "string" && isLanguageTag(search.language) ?
      { language: search.language }
    : {},
  component: GeneralRouteComponent,
});
