//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { type ReactNode } from "react";
import { RouteHeader, RouteHeaderBackLink } from "@/components/ui/RouteHeader";

interface EnrollmentLayoutProps {
  children: ReactNode;
  saveButton: ReactNode;
}

export const EnrollmentLayout = ({
  children,
  saveButton,
}: EnrollmentLayoutProps) => {
  return (
    <div>
      <RouteHeader
        title="Enrollment"
        description="Choose who can enroll in your study and manage invitation codes."
        accessoryLeft={<RouteHeaderBackLink />}
        accessoryRight={saveButton}
      />
      {children}
    </div>
  );
};
