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
import { useState } from "react";
import { z } from "zod";
import {
  zStudyDetailContent,
  zStudyReadinessContent,
  zStudyContact,
} from "@/lib/api/generated/zod.gen";
import { draftHeaders, useDraftFormSnapshot } from "@/lib/queries/draft";
import { studyResponseQueryOptions } from "@/lib/queries/study";
import { generalFormValues, readinessFormFacts } from "./studyDetails";

// Extend the generated StudyDetailContent schema with icon and form-specific
// nullable semantics (form fields can be explicitly cleared)
const generalFormSchema = zStudyDetailContent.extend({
  facts: zStudyReadinessContent,
  contacts: z.array(zStudyContact).max(16),
  title: z.string().min(1, "Title is required"),
  shortTitle: z.string().nullable(),
  icon: z.string().nullable(),
  explanationText: z.string().nullable(),
  shortExplanationText: z.string().nullable(),
});

const defaultValues: z.infer<typeof generalFormSchema> = {
  facts: readinessFormFacts(undefined),
  contacts: [],
  title: "",
  shortTitle: null,
  icon: null,
  explanationText: null,
  shortExplanationText: null,
};

/**
 * Creates the general study form for one language of the study details.
 * Uses the raw StudyResponse so callers can keep the other languages on save.
 */
export const useGeneralForm = (selectedLanguage?: string) => {
  const params = useParams({
    from: "/(dashboard)/$group/$study/configuration/general",
  });
  const { data: studyResponse } = useQuery(
    studyResponseQueryOptions({ studyId: params.study }),
  );

  const [baseline, setBaseline] = useState(studyResponse);
  const language = selectedLanguage ?? baseline?.details.sourceLanguage ?? "";
  const form = useForm({
    formSchema: generalFormSchema,
    defaultValues:
      baseline ? generalFormValues(baseline, language) : defaultValues,
  });

  const getStudySnapshot = useDraftFormSnapshot(
    studyResponse,
    `${params.study}:${selectedLanguage ?? ""}`,
    form.formState.isDirty,
    (loaded) => {
      setBaseline(loaded);
      form.reset(
        generalFormValues(
          loaded,
          selectedLanguage ?? loaded.details.sourceLanguage,
        ),
      );
    },
  );

  return {
    form,
    study: baseline,
    language,
    getStudySnapshot,
    getDraftHeaders: () => draftHeaders(getStudySnapshot().draftRevision),
  };
};

export type GeneralForm = ReturnType<typeof useGeneralForm>["form"];
