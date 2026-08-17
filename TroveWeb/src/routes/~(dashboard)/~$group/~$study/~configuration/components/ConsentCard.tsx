//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { useParams } from "@tanstack/react-router";
import { KeyValueCard } from "@/components/interfaces/KeyValueCard";
import { EditButtonLink } from "@/components/ui/EditButton";
import type { StudyResponse } from "@/lib/api/generated/types.gen";
import { useLocale } from "@/lib/locale";

const countInteractive = (content: string, tag: string) => {
  const pattern = new RegExp(`<${tag}\\b`, "gi");
  let count = 0;
  while (pattern.exec(content) !== null) {
    count += 1;
  }
  return count;
};

interface ConsentCardProps {
  study?: StudyResponse;
  isLoading?: boolean;
}

export const ConsentCard = ({ study, isLoading }: ConsentCardProps) => {
  const params = useParams({
    from: "/(dashboard)/$group/$study/configuration/",
  });
  const { locale } = useLocale();
  const consent = study?.consent[locale];

  const interactiveSummary = (() => {
    if (!consent) return null;
    const toggles = countInteractive(consent.content, "toggle");
    const selects = countInteractive(consent.content, "select");
    const signatures = countInteractive(consent.content, "signature");
    const total = toggles + selects + signatures;
    if (total === 0) return "Plain markdown (no interactive elements)";
    return [
      toggles && `${toggles} toggle${toggles === 1 ? "" : "s"}`,
      selects && `${selects} select${selects === 1 ? "" : "s"}`,
      signatures && `${signatures} signature${signatures === 1 ? "" : "s"}`,
    ]
      .filter(Boolean)
      .join(", ");
  })();

  return (
    <KeyValueCard
      title="Consent"
      description="Author the consent document participants must accept before enrolling."
      actions={
        <EditButtonLink
          aria-label="Edit consent"
          data-testid="edit-consent"
          from="/"
          to="/$group/$study/configuration/consent"
          params={params}
          className="h-8 text-sm"
        />
      }
      isLoading={isLoading}
      items={[
        {
          key: "Title",
          tooltip: "Heading shown above the consent body.",
          value: consent?.title,
        },
        {
          key: "Document length",
          tooltip: "Total characters in the markdown body for this locale.",
          value: consent ? `${consent.content.length} characters` : null,
        },
        {
          key: "Interactive elements",
          tooltip:
            "Counts of <toggle>, <select>, and <signature> blocks in the document.",
          value: interactiveSummary,
        },
      ]}
    />
  );
};
