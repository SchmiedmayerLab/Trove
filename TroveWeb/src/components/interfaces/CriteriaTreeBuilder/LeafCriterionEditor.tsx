//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { Input } from "@schmiedmayerlab/grove-design-system";
import type { ParticipationCriterion } from "@/lib/api/generated/types.gen";

interface LeafCriterionEditorProps {
  criterion: ParticipationCriterion;
  onChange: (criterion: ParticipationCriterion) => void;
}

export const LeafCriterionEditor = ({
  criterion,
  onChange,
}: LeafCriterionEditorProps) => {
  switch (criterion.type) {
    case "ageAtLeast":
      return (
        <Input
          type="number"
          min={0}
          value={criterion.age}
          onChange={(event) =>
            onChange({
              ...criterion,
              age: Number(event.target.value),
            })
          }
          className="w-24"
          aria-label="Minimum age"
        />
      );
    case "isFromRegion":
      return (
        <Input
          type="text"
          value={criterion.region}
          onChange={(event) =>
            onChange({
              ...criterion,
              region: event.target.value,
            })
          }
          placeholder="e.g. US"
          className="w-24"
          aria-label="Region code"
        />
      );
    case "speaksLanguage":
      return (
        <Input
          type="text"
          value={criterion.language}
          onChange={(event) =>
            onChange({
              ...criterion,
              language: event.target.value,
            })
          }
          placeholder="e.g. en"
          className="w-24"
          aria-label="Language code"
        />
      );
    default:
      return null;
  }
};
