// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { useForm } from "@schmiedmayerlab/grove-design-system";
import { useQuery } from "@tanstack/react-query";
import { draftHeaders, useDraftFormSnapshot } from "@/lib/queries/draft";
import { studyResponseQueryOptions } from "@/lib/queries/study";
import { canEditCollection, collectionFormSchema } from "./collectionForm";

export const useCollectionForm = (studyId: string) => {
  const query = useQuery(studyResponseQueryOptions({ studyId }));
  const form = useForm({
    formSchema: collectionFormSchema,
    defaultValues: { collectionRequirements: [] },
  });
  const getSnapshot = useDraftFormSnapshot(
    query.data,
    studyId,
    form.formState.isDirty,
    (loaded) =>
      form.reset({ collectionRequirements: loaded.collectionRequirements }),
  );
  return {
    form,
    query,
    isSupported:
      !!query.data && canEditCollection(query.data.collectionRequirements),
    getDraftHeaders: () => draftHeaders(getSnapshot().draftRevision),
  };
};

export type CollectionForm = ReturnType<typeof useCollectionForm>["form"];
