// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { createFileRoute } from "@tanstack/react-router";
import { FrozenExportPanel } from "@/components/interfaces/StudyData/FrozenExportPanel";
import { StudyDataPanel } from "@/components/interfaces/StudyData/StudyDataPanel";
import { RouteHeader } from "@/components/ui/RouteHeader";

const ResultsRoute = () => {
  const { study } = Route.useParams();
  return (
    <div>
      <RouteHeader
        title="Results"
        description="Study-authorized measurements and FHIR downloads."
      />
      <div className="flex max-w-7xl flex-col gap-6 p-6 pb-12">
        <FrozenExportPanel key={study + "-exports"} studyId={study} />
        <StudyDataPanel key={study} studyId={study} />
      </div>
    </div>
  );
};

export const Route = createFileRoute("/(dashboard)/$group/$study/results")({
  component: ResultsRoute,
});
