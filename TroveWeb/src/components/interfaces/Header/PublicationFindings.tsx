//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import type { ComponentProps } from "react";
import type { StudyDraftValidation } from "@/lib/api/generated/types.gen";
import { ValidationDiagnostics } from "../ValidationDiagnostics";

/**
 * The blockers and advisories of one draft validation. Blockers are listed whenever there is no
 * candidate and receive focus when they appear; advisories do not repeat the overall result.
 */
export const PublicationFindings = ({
  report,
  componentName,
  locate,
}: {
  report: StudyDraftValidation;
  locate?: NonNullable<ComponentProps<typeof ValidationDiagnostics>["locate"]>;
  componentName: (componentId: string) => string | undefined;
}) => {
  const showBlockers = !report.candidate || report.blockers.length > 0;
  const unavailableRoutes = report.routes.filter(
    (route) => route.availability === "unavailable",
  );
  if (
    !showBlockers &&
    report.advisories.length === 0 &&
    unavailableRoutes.length === 0
  )
    return null;
  return (
    <div className="grid gap-4">
      {unavailableRoutes.map((route) => (
        <p key={route.index} className="text-sm break-all">
          Unavailable {route.requirement} collection route: {route.profile} (
          {route.sourceKind})
          {route.providerRegistrationId && (
            <>
              , registration <code>{route.providerRegistrationId}</code>
            </>
          )}
          {route.sourceTypeIdentifier && (
            <>
              , source <code>{route.sourceTypeIdentifier}</code>
            </>
          )}
        </p>
      ))}
      {showBlockers && (
        <ValidationDiagnostics
          key={`blockers:${report.status}`}
          title="Blockers"
          status={report.status}
          diagnostics={report.blockers}
          locate={locate}
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
          locate={locate}
          componentName={componentName}
        />
      )}
    </div>
  );
};
