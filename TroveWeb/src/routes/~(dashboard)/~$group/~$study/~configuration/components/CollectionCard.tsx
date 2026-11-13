// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { useParams } from "@tanstack/react-router";
import { KeyValueCard } from "@/components/interfaces/KeyValueCard";
import { EditButtonLink } from "@/components/ui/EditButton";
import type { StudyResponse } from "@/lib/api/generated/types.gen";
import { collectionSummary } from "../lib/collectionForm";

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
  return (
    <KeyValueCard
      title="Health collection"
      description="Measurements and historical scope requested by this study."
      isLoading={isLoading}
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
          value:
            study ? collectionSummary(study.collectionRequirements) : undefined,
        },
      ]}
    />
  );
};
