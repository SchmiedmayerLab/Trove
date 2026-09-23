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

const participationFormSchema = z.object({
  // z.custom wrapper needed: zParticipationCriterion infers as `any` due to recursive z.lazy in generated code
  participationCriterion: z
    .custom<ParticipationCriterion>()
    .refine((value) => zParticipationCriterion.safeParse(value).success, {
      message: "Invalid participation criterion",
    })
    .nullable(),
});

const defaultValues: z.infer<typeof participationFormSchema> = {
  participationCriterion: null,
};

/**
 * Creates a participation form that loads the study participation criterion once available.
 */
export const useParticipationForm = () => {
  const params = useParams({
    from: "/(dashboard)/$group/$study/configuration/participation",
  });
  const { data: study } = useQuery(
    studyResponseQueryOptions({ studyId: params.study }),
  );

  const formValues =
    study ?
      { participationCriterion: study.participationCriterion }
    : undefined;

  const form = useForm({
    formSchema: participationFormSchema,
    defaultValues: formValues ?? defaultValues,
  });

  const getSnapshot = useDraftFormSnapshot(
    study,
    params.study,
    form.formState.isDirty,
    (loaded) =>
      form.reset({ participationCriterion: loaded.participationCriterion }),
  );

  return {
    form,
    getDraftHeaders: () => draftHeaders(getSnapshot().draftRevision),
  };
};

export type ParticipationForm = ReturnType<typeof useParticipationForm>["form"];
