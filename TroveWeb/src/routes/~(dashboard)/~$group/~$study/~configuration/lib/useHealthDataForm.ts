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
import { healthDataRetrieveQueryOptions } from "@/lib/queries/component";
import { draftHeaders, useDraftFormSnapshot } from "@/lib/queries/draft";
import {
  defaultValues,
  healthDataSchema,
  transformHealthDataFormToInput,
  transformResponseToForm,
} from "./healthDataForm";

export const useHealthDataForm = () => {
  const params = useParams({ strict: false });

  const { data: snapshot } = useQuery({
    ...healthDataRetrieveQueryOptions({
      studyId: params.study ?? "",
      componentId: params.component ?? "",
    }),
    enabled: !!params.study,
  });
  const componentResponse = snapshot?.value;

  const formValues =
    componentResponse ? transformResponseToForm(componentResponse) : undefined;

  const form = useForm({
    formSchema: healthDataSchema,
    defaultValues: formValues ?? defaultValues,
  });

  const getSnapshot = useDraftFormSnapshot(
    snapshot,
    `${params.study}:${params.component}`,
    form.formState.isDirty,
    (loaded) =>
      form.reset(
        loaded.value ? transformResponseToForm(loaded.value) : defaultValues,
      ),
  );

  return {
    form,
    componentData: componentResponse,
    toInput: transformHealthDataFormToInput,
    getDraftHeaders: () => draftHeaders(getSnapshot().draftRevision),
  };
};

export type HealthDataForm = ReturnType<typeof useHealthDataForm>["form"];
