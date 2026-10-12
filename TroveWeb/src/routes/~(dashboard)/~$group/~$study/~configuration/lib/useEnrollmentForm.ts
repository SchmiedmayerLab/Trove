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
import type { ParticipationCriterion } from "@/lib/api/generated/types.gen";
import { zParticipationCriterion } from "@/lib/api/generated/zod.gen";
import { draftHeaders, useDraftFormSnapshot } from "@/lib/queries/draft";
import { studyResponseQueryOptions } from "@/lib/queries/study";

export const enrollmentFormSchema = z.object({
  enrollmentConditions: z.enum(["none", "requiresInvitationCode"]),
  visibility: z.enum(["public", "unlisted"]),
  participationCriterion: z
    .custom<ParticipationCriterion>()
    .refine((value) => zParticipationCriterion.safeParse(value).success, {
      message: "Invalid participation criterion",
    })
    .nullable(),
});

const defaultValues: z.infer<typeof enrollmentFormSchema> = {
  enrollmentConditions: "none",
  visibility: "public",
  participationCriterion: null,
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
        participationCriterion: studyResponse.participationCriterion,
      }
    : undefined;

  const form = useForm({
    formSchema: enrollmentFormSchema,
    defaultValues: formValues ?? defaultValues,
  });

  const getSnapshot = useDraftFormSnapshot(
    studyResponse,
    params.study,
    form.formState.isDirty,
    (loaded) =>
      form.reset({
        enrollmentConditions: loaded.enrollmentConditions,
        visibility: loaded.visibility,
        participationCriterion: loaded.participationCriterion,
      }),
  );

  return {
    form,
    studyResponse,
    getDraftHeaders: () => draftHeaders(getSnapshot().draftRevision),
  };
};

export type EnrollmentForm = ReturnType<typeof useEnrollmentForm>["form"];
