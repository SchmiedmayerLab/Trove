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
import { questionnaireRetrieveQueryOptions } from "@/lib/queries/component";
import { draftHeaders, useDraftFormSnapshot } from "@/lib/queries/draft";
import {
  emptyQuestionnaireForm,
  questionnaireFormSchema,
  questionnaireFormValues,
  questionnaireInput,
  type QuestionnaireFormValues,
} from "./questionnaireForm";

/** Edits the component's one multilingual FHIR Questionnaire as JSON text. */
export const useQuestionnaireForm = () => {
  const params = useParams({ strict: false });

  const { data: snapshot } = useQuery({
    ...questionnaireRetrieveQueryOptions({
      studyId: params.study ?? "",
      componentId: params.component ?? "",
    }),
    enabled: !!params.study,
  });
  const componentResponse = snapshot?.value;

  const form = useForm({
    formSchema: questionnaireFormSchema,
    defaultValues:
      componentResponse ?
        questionnaireFormValues(componentResponse)
      : emptyQuestionnaireForm,
  });

  const getSnapshot = useDraftFormSnapshot(
    snapshot,
    `${params.study}:${params.component}`,
    form.formState.isDirty,
    (loaded) =>
      form.reset(
        loaded.value ?
          questionnaireFormValues(loaded.value)
        : emptyQuestionnaireForm,
      ),
  );

  return {
    form,
    componentData: componentResponse,
    toInput: (formData: QuestionnaireFormValues) =>
      questionnaireInput(formData),
    getDraftHeaders: () => draftHeaders(getSnapshot().draftRevision),
  };
};

export type QuestionnaireForm = ReturnType<typeof useQuestionnaireForm>["form"];
