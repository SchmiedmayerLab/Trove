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
  HealthDataComponentInput,
  HealthDataComponentResponse,
} from "@/lib/api/generated/types.gen";
import { zSampleTypesCollection } from "@/lib/api/generated/zod.gen";
import { healthDataRetrieveQueryOptions } from "@/lib/queries/component";
import { draftHeaders, useDraftFormSnapshot } from "@/lib/queries/draft";

const healthDataSchema = z.object({
  name: z.string().min(1, "Name is required"),
  sampleTypes: zSampleTypesCollection.min(
    1,
    "At least one sample type is required",
  ),
});

const defaultValues: z.infer<typeof healthDataSchema> = {
  name: "Health Data",
  sampleTypes: [],
};

const transformResponseToForm = (response: HealthDataComponentResponse) => ({
  name: response.name,
  sampleTypes: response.data.sampleTypes,
});

const transformHealthDataFormToInput = (
  formData: z.infer<typeof healthDataSchema>,
): HealthDataComponentInput => ({
  name: formData.name,
  data: {
    sampleTypes: formData.sampleTypes,
  },
});

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
