//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import type { StudyDraftValidation } from "@/lib/api/generated/types.gen";
import { ValidationDiagnostics } from "../ValidationDiagnostics";

/**
 * The blockers and advisories of one draft validation. Blockers are listed whenever there is no
 * candidate and receive focus when they appear; advisories do not repeat the overall result.
 */
export const PublicationFindings = ({
  report,
  componentName,
}: {
  report: StudyDraftValidation;
  componentName: (componentId: string) => string | undefined;
}) => {
  const showBlockers = !report.candidate || report.blockers.length > 0;
  if (!showBlockers && report.advisories.length === 0) return null;
  return (
    <div className="grid gap-4">
      {showBlockers && (
        <ValidationDiagnostics
          key={`blockers:${report.status}`}
          title="Blockers"
          status={report.status}
          diagnostics={report.blockers}
          componentName={componentName}
          focusOnMount
        />
      )}
      {report.advisories.length > 0 && (
        <ValidationDiagnostics
          title="Advisories"
          status={report.status}
          showStatus={false}
          diagnostics={report.advisories}
          componentName={componentName}
        />
      )}
    </div>
  );
};
