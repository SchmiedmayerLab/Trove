//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import {
  Button,
  Field,
  Input,
  Textarea,
} from "@schmiedmayerlab/grove-design-system";
import {
  useRef,
  useState,
  type BaseSyntheticEvent,
  type ChangeEvent,
} from "react";
import { ValidationDiagnostics } from "@/components/interfaces/ValidationDiagnostics";
import { CardHeader } from "@/components/ui/Card";
import { FieldLabel } from "@/components/ui/FieldLabel";
import type {
  QuestionnaireValidation,
  ValidationDiagnostic,
} from "@/lib/api/generated/types.gen";
import { useValidateComponentMutation } from "@/lib/queries/component";
import { questionnaireLanguages } from "@/lib/questionnaireLanguages";
import { itemLinkId, linkIdRange } from "@/lib/validationDiagnostics";
import { enhanceField } from "@/utils/enhanceField";
import { shownValidation } from "../../lib/questionnaireForm";
import type { QuestionnaireForm } from "../../lib/useQuestionnaireForm";

// Reformatting rewrites the resource, so it only happens on request.
const formatJson = (json: string): string =>
  JSON.stringify(JSON.parse(json), null, 2);

const downloadFile = (content: string, filename: string) => {
  const blob = new Blob([content], { type: "application/json" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = filename;
  document.body.appendChild(link);
  link.click();
  document.body.removeChild(link);
  URL.revokeObjectURL(url);
};

/**
 * Validates the saved component and lists its findings. A result is shown only for the saved
 * revision it describes and only while there are no unsaved changes.
 */
const QuestionnaireValidationSection = ({
  studyId,
  componentId,
  savedRevision,
  hasUnsavedChanges,
  locate,
}: {
  studyId: string;
  componentId: string;
  savedRevision: string | undefined;
  hasUnsavedChanges: boolean;
  locate: (
    diagnostic: ValidationDiagnostic,
  ) => { target: string; show: () => void } | undefined;
}) => {
  const validate = useValidateComponentMutation();
  const [result, setResult] = useState<QuestionnaireValidation>();
  const shown = shownValidation(result, savedRevision, hasUnsavedChanges);

  return (
    <div className="border-border-tertiary grid gap-3 border-t px-6 pt-6">
      <FieldLabel
        title="Validation"
        description="Checks the saved questionnaire with the FHIR Validator, the Grove questionnaire rules and the study app's supported features. Publishing validates the draft again."
      />
      {hasUnsavedChanges && (
        <p className="text-text-secondary text-sm">
          Save your changes to validate them.
        </p>
      )}
      <div>
        <Button
          type="button"
          size="xs"
          variant="outlineBg"
          disabled={hasUnsavedChanges || validate.isPending}
          isPending={validate.isPending}
          onClick={() => {
            setResult(undefined);
            validate.mutate(
              { path: { studyId, componentId } },
              { onSuccess: setResult },
            );
          }}
        >
          Validate saved questionnaire
        </Button>
      </div>
      {shown && (
        <ValidationDiagnostics
          key={`${shown.sha256}:${shown.draftRevision}`}
          title="Validation result"
          status={shown.status}
          diagnostics={shown.diagnostics}
          locate={locate}
          focusOnMount
        />
      )}
    </div>
  );
};

interface QuestionnaireComponentFormProps {
  form: QuestionnaireForm;
  onSubmit: (event?: BaseSyntheticEvent) => Promise<void>;
  /** The saved component to validate and its draft revision; omitted while creating one. */
  saved?: {
    studyId: string;
    componentId: string;
    revision: string | undefined;
  };
}

export const QuestionnaireComponentForm = ({
  form,
  onSubmit,
  saved,
}: QuestionnaireComponentFormProps) => {
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const editorRef = useRef<HTMLDivElement | null>(null);
  const questionnaireJson = form.watch("questionnaire");

  const locate = (diagnostic: ValidationDiagnostic) => {
    const linkId = itemLinkId(questionnaireJson, diagnostic.path);
    const range = linkId && linkIdRange(questionnaireJson, linkId);
    if (!range) return undefined;
    return {
      target: linkId,
      show: () => {
        const textarea = editorRef.current?.querySelector("textarea");
        textarea?.focus();
        textarea?.setSelectionRange(...range);
      },
    };
  };

  const setQuestionnaireJson = (json: string) => {
    form.setValue("questionnaire", json, {
      shouldDirty: true,
      shouldTouch: true,
      shouldValidate: true,
    });
    form.clearErrors("questionnaire");
  };

  const setQuestionnaireError = (message: string) => {
    form.setError("questionnaire", { message });
  };

  const handleFileUpload = async (event: ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    if (!file) return;

    try {
      const text = await file.text();
      JSON.parse(text);
      setQuestionnaireJson(text);
    } catch {
      setQuestionnaireError(
        "Invalid JSON file. Please upload a valid JSON document.",
      );
    } finally {
      event.target.value = "";
    }
  };

  const handleDownload = () => {
    if (!questionnaireJson.trim()) {
      setQuestionnaireError("There is no JSON to download yet.");
      return;
    }

    downloadFile(questionnaireJson, "questionnaire.json");
    form.clearErrors("questionnaire");
  };

  const handleFormat = () => {
    if (!questionnaireJson.trim()) return;

    try {
      setQuestionnaireJson(formatJson(questionnaireJson));
    } catch {
      setQuestionnaireError(
        "JSON is invalid. Please fix it before formatting.",
      );
    }
  };

  const languages = questionnaireLanguages(questionnaireJson);

  return (
    <>
      <CardHeader
        title="Questionnaire component"
        description="Collect questionnaire responses from participants."
      />
      <form onSubmit={onSubmit} className="py-6">
        <Field
          control={form.control}
          name="name"
          label={
            <FieldLabel
              title="Name"
              description="An internal identifier for this component."
            />
          }
          className="border-border-tertiary border-b px-6"
          render={({ field }) => <Input {...enhanceField(field)} />}
        />
        <Field
          control={form.control}
          name="questionnaire"
          label={
            <FieldLabel
              title="FHIR questionnaire JSON"
              description="One FHIR Questionnaire for every language: Questionnaire.language names the base language, and translation extensions carry the others. Upload and download keep the text without reformatting."
            />
          }
          className="px-6 pt-6"
          render={({ field }) => (
            <div ref={editorRef}>
              <Textarea {...field} rows={10} className="w-full font-mono" />
              {languages ?
                <dl className="text-text-secondary grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 pt-3 text-sm">
                  <dt className="font-medium">Base language</dt>
                  <dd>{languages.base ?? "Not named"}</dd>
                  <dt className="font-medium">Translations</dt>
                  <dd>
                    {languages.translations.length > 0 ?
                      languages.translations.join(", ")
                    : "None"}
                  </dd>
                </dl>
              : <p className="text-text-secondary pt-3 text-sm">Invalid JSON</p>
              }
              <div className="flex flex-wrap justify-end gap-2 pt-4">
                <input
                  ref={fileInputRef}
                  type="file"
                  accept="application/json,application/fhir+json"
                  className="hidden"
                  onChange={handleFileUpload}
                />
                <Button
                  type="button"
                  size="xs"
                  variant="outlineBg"
                  onClick={() => fileInputRef.current?.click()}
                >
                  Upload JSON
                </Button>
                <Button
                  type="button"
                  size="xs"
                  variant="outlineBg"
                  onClick={handleDownload}
                >
                  Download JSON
                </Button>
                <Button
                  type="button"
                  size="xs"
                  variant="outlineBg"
                  onClick={handleFormat}
                >
                  Format JSON
                </Button>
              </div>
            </div>
          )}
        />
      </form>
      {saved && (
        <QuestionnaireValidationSection
          studyId={saved.studyId}
          componentId={saved.componentId}
          savedRevision={saved.revision}
          hasUnsavedChanges={form.formState.isDirty}
          locate={locate}
        />
      )}
    </>
  );
};
