// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { z } from "zod";
import type {
  QuestionnaireComponentInput,
  QuestionnaireComponentResponse,
} from "@/lib/api/generated/types.gen";
import { zQuestionnaireContent } from "@/lib/api/generated/zod.gen";

export const questionnaireFormSchema = zQuestionnaireContent.extend({
  name: z.string().min(1, "Name is required"),
  questionnaire: z
    .string()
    .min(1, "Questionnaire JSON is required")
    .refine((value) => {
      try {
        JSON.parse(value);
        return true;
      } catch {
        return false;
      }
    }, "Invalid FHIR Questionnaire JSON"),
});

export type QuestionnaireFormValues = z.infer<typeof questionnaireFormSchema>;

export const emptyQuestionnaireForm: QuestionnaireFormValues = {
  name: "",
  questionnaire: "",
};

/** The component's one multilingual resource, as its exact text. */
export const questionnaireFormValues = (
  response: QuestionnaireComponentResponse,
): QuestionnaireFormValues => ({
  name: response.name,
  questionnaire: response.data.questionnaire,
});

export const questionnaireInput = (
  values: QuestionnaireFormValues,
): QuestionnaireComponentInput => ({
  name: values.name,
  data: { questionnaire: values.questionnaire },
});

/**
 * A component validation result is shown only for the saved revision it describes and only while
 * the form has no unsaved changes; any other result describes text the form no longer shows.
 */
export const shownValidation = <Result extends { draftRevision: string }>(
  result: Result | undefined,
  savedRevision: string | undefined,
  hasUnsavedChanges: boolean,
): Result | undefined =>
  result && !hasUnsavedChanges && result.draftRevision === savedRevision ?
    result
  : undefined;
