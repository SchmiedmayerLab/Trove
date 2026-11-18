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
import { useRef, type BaseSyntheticEvent, type ChangeEvent } from "react";
import { CardHeader } from "@/components/ui/Card";
import { FieldLabel } from "@/components/ui/FieldLabel";
import { questionnaireLanguages } from "@/lib/questionnaireLanguages";
import { enhanceField } from "@/utils/enhanceField";
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

interface QuestionnaireComponentFormProps {
  form: QuestionnaireForm;
  onSubmit: (event?: BaseSyntheticEvent) => Promise<void>;
}

export const QuestionnaireComponentForm = ({
  form,
  onSubmit,
}: QuestionnaireComponentFormProps) => {
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const questionnaireJson = form.watch("questionnaire");

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
            <div>
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
    </>
  );
};
