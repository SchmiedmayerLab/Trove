// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { useForm } from "@schmiedmayerlab/grove-design-system";
import { useQuery } from "@tanstack/react-query";
import { useState } from "react";
import {
  getCollectionCapabilitiesOptions,
  getStudyCollectionProviderCapabilitiesOptions,
} from "@/lib/api/generated/@tanstack/react-query.gen";
import { draftHeaders, useDraftFormSnapshot } from "@/lib/queries/draft";
import { studyResponseQueryOptions } from "@/lib/queries/study";
import {
  canEditCollection,
  makeCollectionFormSchema,
  measurementsFromCapabilities,
  measurementsFromProviderRegistrations,
} from "./collectionForm";

export const useCollectionForm = (studyId: string) => {
  const query = useQuery(studyResponseQueryOptions({ studyId }));
  const capabilities = useQuery(getCollectionCapabilitiesOptions());
  const providers = useQuery(
    getStudyCollectionProviderCapabilitiesOptions({ path: { studyId } }),
  );
  const measurements = [
    ...measurementsFromCapabilities(capabilities.data ?? []),
    ...measurementsFromProviderRegistrations(providers.data ?? []),
  ];
  const [baseline, setBaseline] = useState(query.data);
  const form = useForm({
    formSchema: makeCollectionFormSchema(
      measurements,
      baseline?.collectionRequirements,
    ),
    defaultValues: {
      collectionRequirements: [],
      receivesDeviceUnitIdentifiers: false,
    },
  });
  const getSnapshot = useDraftFormSnapshot(
    query.data,
    studyId,
    form.formState.isDirty,
    (loaded) => {
      setBaseline(loaded);
      form.reset({
        collectionRequirements: loaded.collectionRequirements,
        receivesDeviceUnitIdentifiers: loaded.receivesDeviceUnitIdentifiers,
      });
    },
  );
  return {
    form,
    query,
    capabilities,
    providers,
    measurements,
    isSupported:
      !!baseline &&
      baseline.id === query.data?.id &&
      !!capabilities.data &&
      !!providers.data &&
      canEditCollection(
        baseline.collectionRequirements,
        measurements,
        baseline.collectionRequirements,
      ),
    getDraftHeaders: () => draftHeaders(getSnapshot().draftRevision),
  };
};

export type CollectionForm = ReturnType<typeof useCollectionForm>["form"];
