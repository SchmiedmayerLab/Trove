//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { Button } from "@schmiedmayerlab/grove-design-system";
import { CircleX, Info, TriangleAlert } from "lucide-react";
import { useEffect, useId, useRef } from "react";
import type {
  ValidationDiagnostic,
  ValidationStatus,
} from "@/lib/api/generated/types.gen";
import {
  severityLabel,
  sourceLabel,
  statusSummary,
} from "@/lib/validationDiagnostics";

const severityIcon = {
  error: CircleX,
  warning: TriangleAlert,
  information: Info,
};

interface ValidationDiagnosticsProps {
  title: string;
  status: ValidationStatus;
  diagnostics: ValidationDiagnostic[];
  /** Names a component by its ID, for findings of a draft validation. */
  componentName?: (componentId: string) => string | undefined;
  /** Shows the element a finding concerns, when that element can be found, naming it in the action. */
  locate?: (
    diagnostic: ValidationDiagnostic,
  ) => { target: string; show: () => void } | undefined;
  /** Whether to state the overall result; a second list of the same result omits it. */
  showStatus?: boolean;
  /** Moves focus to the heading when a new result appears, instead of announcing it. */
  focusOnMount?: boolean;
}

/**
 * Lists validation findings with their severity in text, rule, element path and translation language.
 * The result is static content: nothing is announced while it is shown.
 */
export const ValidationDiagnostics = ({
  title,
  status,
  diagnostics,
  componentName,
  locate,
  showStatus = true,
  focusOnMount = false,
}: ValidationDiagnosticsProps) => {
  const headingId = useId();
  const statusId = useId();
  const headingRef = useRef<HTMLHeadingElement>(null);
  useEffect(() => {
    if (focusOnMount) headingRef.current?.focus();
  }, [focusOnMount]);

  return (
    <section aria-labelledby={headingId} className="grid gap-2 text-sm">
      <h3
        id={headingId}
        ref={headingRef}
        tabIndex={-1}
        aria-describedby={showStatus ? statusId : undefined}
        className="focus:ring-border-focus rounded-sm font-medium outline-hidden focus:ring-2"
      >
        {title}
      </h3>
      {showStatus && <p id={statusId}>{statusSummary[status]}</p>}
      {diagnostics.length > 0 && (
        <ul className="grid gap-2">
          {diagnostics.map((diagnostic, index) => {
            const Icon = severityIcon[diagnostic.severity];
            const location = locate?.(diagnostic);
            const component =
              diagnostic.componentId &&
              (componentName?.(diagnostic.componentId) ??
                diagnostic.componentId);
            return (
              <li
                // eslint-disable-next-line @eslint-react/no-array-index-key -- findings carry no identity, and one result's order is fixed
                key={index}
                className="border-border-tertiary grid gap-1 rounded-md border p-3"
              >
                <p className="flex items-start gap-2">
                  <Icon aria-hidden className="mt-0.5 size-4 shrink-0" />
                  <span>
                    <span className="font-medium">
                      {severityLabel[diagnostic.severity]}:
                    </span>{" "}
                    {diagnostic.message}
                  </span>
                </p>
                {diagnostic.nextAction && <p>{diagnostic.nextAction}</p>}
                <dl className="text-text-secondary grid grid-cols-[auto_1fr] gap-x-3 text-xs break-all">
                  {component && (
                    <>
                      <dt>Component</dt>
                      <dd>{component}</dd>
                    </>
                  )}
                  {diagnostic.path && (
                    <>
                      <dt>Element</dt>
                      <dd className="font-mono">{diagnostic.path}</dd>
                    </>
                  )}
                  {diagnostic.language && (
                    <>
                      <dt>Language</dt>
                      <dd>{diagnostic.language}</dd>
                    </>
                  )}
                  <dt>Rule</dt>
                  <dd>
                    {sourceLabel[diagnostic.source]}:{" "}
                    <span className="font-mono">{diagnostic.rule}</span>
                  </dd>
                </dl>
                {location && (
                  <div>
                    <Button
                      type="button"
                      size="xs"
                      variant="outlineBg"
                      onClick={location.show}
                    >
                      Show item {location.target} in JSON
                    </Button>
                  </div>
                )}
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
};
