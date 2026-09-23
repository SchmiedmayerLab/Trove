//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { useForm } from "@schmiedmayerlab/grove-design-system";
import { useQuery } from "@tanstack/react-query";
import { useParams } from "@tanstack/react-router";
import { z } from "zod";
import type {
  QuestionnaireComponentData,
  QuestionnaireComponentInput,
  QuestionnaireComponentResponse,
  QuestionnaireContent,
} from "@/lib/api/generated/types.gen";
import { zQuestionnaireContent } from "@/lib/api/generated/zod.gen";
import { questionnaireRetrieveQueryOptions } from "@/lib/queries/component";
import { draftHeaders, useDraftFormSnapshot } from "@/lib/queries/draft";

const questionnaireSchema = zQuestionnaireContent.extend({
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

const defaultValues: z.infer<typeof questionnaireSchema> = {
  name: "",
  questionnaire: "",
};

const transformResponseToForm = (
  response: QuestionnaireComponentResponse,
  locale: string,
) => {
  const localeData = response.data[locale] as QuestionnaireContent | undefined;
  return {
    name: response.name,
    questionnaire: localeData?.questionnaire ?? "",
  };
};

const transformQuestionnaireFormToInput = (
  formData: z.infer<typeof questionnaireSchema>,
  locale: string,
  existingData?: QuestionnaireComponentData,
): QuestionnaireComponentInput => ({
  name: formData.name,
  data: {
    ...existingData,
    [locale]: {
      questionnaire: formData.questionnaire,
    },
  },
});

export const useQuestionnaireForm = (locale: string) => {
  const params = useParams({ strict: false });

  const { data: snapshot } = useQuery({
    ...questionnaireRetrieveQueryOptions({
      studyId: params.study ?? "",
      componentId: params.component ?? "",
    }),
    enabled: !!params.study,
  });
  const componentResponse = snapshot?.value;

  const formValues =
    componentResponse ?
      transformResponseToForm(componentResponse, locale)
    : undefined;

  const form = useForm({
    formSchema: questionnaireSchema,
    defaultValues: formValues ?? defaultValues,
  });

  const getSnapshot = useDraftFormSnapshot(
    snapshot,
    `${params.study}:${params.component}:${locale}`,
    form.formState.isDirty,
    (loaded) =>
      form.reset(
        loaded.value ?
          transformResponseToForm(loaded.value, locale)
        : defaultValues,
      ),
  );

  const toInput = (formData: z.infer<typeof questionnaireSchema>) =>
    transformQuestionnaireFormToInput(
      formData,
      locale,
      getSnapshot().value?.data,
    );

  return {
    form,
    componentData: componentResponse,
    toInput,
    getDraftHeaders: () => draftHeaders(getSnapshot().draftRevision),
  };
};

export type QuestionnaireForm = ReturnType<typeof useQuestionnaireForm>["form"];
