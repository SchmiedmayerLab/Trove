//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { useForm } from "@stanfordspezi/spezi-web-design-system";
import { useQuery } from "@tanstack/react-query";
import { useParams } from "@tanstack/react-router";
import { useEffect } from "react";
import { z } from "zod";
import { studyResponseQueryOptions } from "@/lib/queries/study";

export const consentFormSchema = z.object({
  title: z.string().min(1, "Title is required"),
  content: z.string(),
});

const defaultValues: z.infer<typeof consentFormSchema> = {
  title: "",
  content: "",
};

export const useConsentForm = (locale: string) => {
  const params = useParams({
    from: "/(dashboard)/$group/$study/configuration/consent",
  });
  const { data: studyResponse } = useQuery(
    studyResponseQueryOptions({ studyId: params.study }),
  );

  const localeConsent = studyResponse?.consent[locale];

  const formValues =
    studyResponse ?
      {
        title: localeConsent?.title ?? "",
        content: localeConsent?.content ?? "",
      }
    : undefined;

  const form = useForm({
    formSchema: consentFormSchema,
    defaultValues: formValues ?? defaultValues,
  });

  useEffect(() => {
    if (formValues) form.reset(formValues);
    // form.reset identity changes every render
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [studyResponse, locale]);

  return { form, studyResponse };
};

export type ConsentForm = ReturnType<typeof useConsentForm>["form"];
