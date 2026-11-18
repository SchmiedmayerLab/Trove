// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { useQuery } from "@tanstack/react-query";
import { useParams } from "@tanstack/react-router";
import { KeyValueCard } from "@/components/interfaces/KeyValueCard";
import { EditButtonLink } from "@/components/ui/EditButton";
import {
  getCollectionCapabilitiesOptions,
  getStudyCollectionProviderCapabilitiesOptions,
} from "@/lib/api/generated/@tanstack/react-query.gen";
import type { StudyResponse } from "@/lib/api/generated/types.gen";
import {
  collectionSummary,
  measurementsFromCapabilities,
  measurementsFromProviderRegistrations,
} from "../lib/collectionForm";

export const CollectionCard = ({
  study,
  isLoading,
}: {
  study?: StudyResponse;
  isLoading?: boolean;
}) => {
  const params = useParams({
    from: "/(dashboard)/$group/$study/configuration/",
  });
  const capabilities = useQuery(getCollectionCapabilitiesOptions());
  const providers = useQuery(
    getStudyCollectionProviderCapabilitiesOptions({
      path: { studyId: params.study },
    }),
  );
  const measurements = [
    ...measurementsFromCapabilities(capabilities.data ?? []),
    ...measurementsFromProviderRegistrations(providers.data ?? []),
  ];
  let summary: string | undefined;
  if (study)
    summary = collectionSummary(study.collectionRequirements, measurements);
  if (capabilities.isError || providers.isError)
    summary = "Collection capabilities could not be loaded.";
  return (
    <KeyValueCard
      title="Health collection"
      description="Measurements and historical scope requested by this study."
      isLoading={
        (isLoading ?? false) || capabilities.isPending || providers.isPending
      }
      actions={
        <EditButtonLink
          aria-label="Edit health collection"
          data-testid="edit-collection"
          from="/"
          to="/$group/$study/configuration/collection"
          params={params}
          className="h-8 text-sm"
        />
      }
      items={[
        {
          key: "Collection scope",
          value: summary,
        },
        {
          key: "Device unit identifiers",
          value:
            study &&
            (study.receivesDeviceUnitIdentifiers ? "Included" : "Withheld"),
        },
      ]}
    />
  );
};
