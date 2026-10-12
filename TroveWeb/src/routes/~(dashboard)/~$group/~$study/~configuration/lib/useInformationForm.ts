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
  InformationalComponentData,
  InformationalComponentInput,
  InformationalComponentResponse,
  InformationalContent,
} from "@/lib/api/generated/types.gen";
import { zInformationalContent } from "@/lib/api/generated/zod.gen";
import { informationalRetrieveQueryOptions } from "@/lib/queries/component";
import { draftHeaders, useDraftFormSnapshot } from "@/lib/queries/draft";

const informationSchema = zInformationalContent.extend({
  name: z.string().min(1, "Name is required"),
  title: z.string().min(1, "Title is required"),
  content: z.string().min(1, "Content is required"),
});

const defaultValues: z.infer<typeof informationSchema> = {
  name: "",
  title: "",
  lede: "",
  content: "",
};

const transformResponseToForm = (
  response: InformationalComponentResponse,
  locale: string,
) => {
  const localeData = response.data[locale] as InformationalContent | undefined;
  return {
    name: response.name,
    title: localeData?.title ?? "",
    lede: localeData?.lede ?? "",
    content: localeData?.content ?? "",
  };
};

const transformInformationFormToInput = (
  formData: z.infer<typeof informationSchema>,
  locale: string,
  existingData?: InformationalComponentData,
): InformationalComponentInput => ({
  name: formData.name,
  data: {
    ...existingData,
    [locale]: {
      title: formData.title,
      lede: formData.lede,
      content: formData.content,
    },
  },
});

export const useInformationForm = (locale: string) => {
  const params = useParams({ strict: false });

  const { data: snapshot } = useQuery({
    ...informationalRetrieveQueryOptions({
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
    formSchema: informationSchema,
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

  const toInput = (formData: z.infer<typeof informationSchema>) =>
    transformInformationFormToInput(
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

export type InformationForm = ReturnType<typeof useInformationForm>["form"];
