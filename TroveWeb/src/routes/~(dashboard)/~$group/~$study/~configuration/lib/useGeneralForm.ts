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
import type { StudyDetailContent } from "@/lib/api/generated/types.gen";
import { zStudyDetailContent } from "@/lib/api/generated/zod.gen";
import { draftHeaders, useDraftFormSnapshot } from "@/lib/queries/draft";
import { studyResponseQueryOptions } from "@/lib/queries/study";

// Extend the generated StudyDetailContent schema with icon and form-specific
// nullable semantics (form fields can be explicitly cleared)
const generalFormSchema = zStudyDetailContent.extend({
  title: z.string().min(1, "Title is required"),
  shortTitle: z.string().nullable(),
  icon: z.string().nullable(),
  explanationText: z.string().nullable(),
  shortExplanationText: z.string().nullable(),
});

const defaultValues: z.infer<typeof generalFormSchema> = {
  title: "",
  shortTitle: null,
  icon: null,
  explanationText: null,
  shortExplanationText: null,
};

/**
 * Creates the general study form for a specific locale.
 * Uses the raw StudyResponse so callers can access `details` for locale preservation on save.
 */
export const useGeneralForm = (locale: string) => {
  const params = useParams({
    from: "/(dashboard)/$group/$study/configuration/general",
  });
  const { data: studyResponse } = useQuery(
    studyResponseQueryOptions({ studyId: params.study }),
  );

  const localeDetails = studyResponse?.details[locale];

  const formValues =
    studyResponse ?
      {
        title: localeDetails?.title ?? "",
        shortTitle: localeDetails?.shortTitle ?? null,
        icon: studyResponse.icon,
        explanationText: localeDetails?.explanationText ?? null,
        shortExplanationText: localeDetails?.shortExplanationText ?? null,
      }
    : undefined;

  const form = useForm({
    formSchema: generalFormSchema,
    defaultValues: formValues ?? defaultValues,
  });

  const getStudySnapshot = useDraftFormSnapshot(
    studyResponse,
    `${params.study}:${locale}`,
    form.formState.isDirty,
    (loaded) => {
      const details = loaded.details[locale] as StudyDetailContent | undefined;
      form.reset({
        title: details?.title ?? "",
        shortTitle: details?.shortTitle ?? null,
        icon: loaded.icon,
        explanationText: details?.explanationText ?? null,
        shortExplanationText: details?.shortExplanationText ?? null,
      });
    },
  );

  return {
    form,
    studyResponse,
    getStudySnapshot,
    getDraftHeaders: () => draftHeaders(getStudySnapshot().draftRevision),
  };
};

export type GeneralForm = ReturnType<typeof useGeneralForm>["form"];
