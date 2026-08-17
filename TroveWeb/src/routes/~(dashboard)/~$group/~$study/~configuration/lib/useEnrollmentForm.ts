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
import { useEffect } from "react";
import { z } from "zod";
import { studyResponseQueryOptions } from "@/lib/queries/study";

export const enrollmentFormSchema = z.object({
  enrollmentConditions: z.enum(["none", "requiresInvitationCode"]),
  visibility: z.enum(["public", "unlisted"]),
});

const defaultValues: z.infer<typeof enrollmentFormSchema> = {
  enrollmentConditions: "none",
  visibility: "public",
};

export const useEnrollmentForm = () => {
  const params = useParams({
    from: "/(dashboard)/$group/$study/configuration/enrollment",
  });
  const { data: studyResponse } = useQuery(
    studyResponseQueryOptions({ studyId: params.study }),
  );

  const formValues =
    studyResponse ?
      {
        enrollmentConditions: studyResponse.enrollmentConditions,
        visibility: studyResponse.visibility,
      }
    : undefined;

  const form = useForm({
    formSchema: enrollmentFormSchema,
    defaultValues: formValues ?? defaultValues,
  });

  useEffect(() => {
    if (formValues) form.reset(formValues);
    // form.reset identity changes every render
    // eslint-disable-next-line @eslint-react/exhaustive-deps
  }, [studyResponse]);

  return { form, studyResponse };
};

export type EnrollmentForm = ReturnType<typeof useEnrollmentForm>["form"];
