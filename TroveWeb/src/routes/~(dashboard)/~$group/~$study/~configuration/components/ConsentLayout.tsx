//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { type ReactNode } from "react";
import { RouteHeader, RouteHeaderBackLink } from "@/components/ui/RouteHeader";

interface ConsentLayoutProps {
  children: ReactNode;
  saveButton: ReactNode;
}

export const ConsentLayout = ({ children, saveButton }: ConsentLayoutProps) => {
  return (
    <div>
      <RouteHeader
        title="Consent"
        description="Author the consent document participants must accept before enrolling."
        accessoryLeft={<RouteHeaderBackLink />}
        accessoryRight={saveButton}
      />
      {children}
    </div>
  );
};
