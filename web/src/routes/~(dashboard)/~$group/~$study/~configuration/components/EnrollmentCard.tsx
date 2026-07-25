//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { useQuery } from "@tanstack/react-query";
import { useParams } from "@tanstack/react-router";
import { KeyValueCard } from "@/components/interfaces/KeyValueCard";
import { EditButtonLink } from "@/components/ui/EditButton";
import type { StudyResponse } from "@/lib/api/generated/types.gen";
import { invitationCodeListQueryOptions } from "@/lib/queries/invitationCode";

const enrollmentModeLabel: Record<
  StudyResponse["enrollmentConditions"],
  string
> = {
  none: "Open to anyone",
  requiresInvitationCode: "Requires invitation code",
};

const visibilityLabel: Record<StudyResponse["visibility"], string> = {
  public: "Public (listed in marketplace)",
  unlisted: "Unlisted (hidden from marketplace)",
};

interface EnrollmentCardProps {
  study?: StudyResponse;
  isLoading?: boolean;
}

export const EnrollmentCard = ({ study, isLoading }: EnrollmentCardProps) => {
  const params = useParams({
    from: "/(dashboard)/$group/$study/configuration/",
  });
  const requiresCodes =
    study?.enrollmentConditions === "requiresInvitationCode";
  const { data: codes } = useQuery({
    ...invitationCodeListQueryOptions({ studyId: params.study }),
    enabled: requiresCodes,
  });

  return (
    <KeyValueCard
      title="Enrollment"
      description="Choose who can enroll in your study and manage invitation codes."
      actions={
        <EditButtonLink
          aria-label="Edit enrollment settings"
          data-testid="edit-enrollment"
          from="/"
          to="/$group/$study/configuration/enrollment"
          params={params}
          className="h-8 text-sm"
        />
      }
      isLoading={isLoading}
      items={[
        {
          key: "Mode",
          tooltip:
            "How participants gain access. Open studies allow anyone to enroll; gated studies require an invitation code.",
          value: study ? enrollmentModeLabel[study.enrollmentConditions] : null,
        },
        {
          key: "Visibility",
          tooltip:
            "Whether the published study appears in the public study marketplace.",
          value: study ? visibilityLabel[study.visibility] : null,
        },
        {
          key: "Invitation codes",
          tooltip: "Total number of codes generated for this study.",
          value: requiresCodes && codes ? `${codes.length} generated` : null,
        },
      ]}
    />
  );
};
