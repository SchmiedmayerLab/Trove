//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { useQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { RouteHeader } from "@/components/ui/RouteHeader";
import { componentListQueryOptions } from "@/lib/queries/component";
import { studyResponseQueryOptions } from "@/lib/queries/study";
import { ComponentsCard } from "./components/ComponentsCard/ComponentsCard";
import { ConsentCard } from "./components/ConsentCard";
import { EnrollmentCard } from "./components/EnrollmentCard";
import { GeneralCard } from "./components/GeneralCard";
import { ParticipationCriteriaCard } from "./components/ParticipationCriteriaCard";

const StudyConfigurationRoute = () => {
  const params = Route.useParams();
  const { data: study, ...studyQuery } = useQuery(
    studyResponseQueryOptions({ studyId: params.study }),
  );
  const { data: components, ...componentQuery } = useQuery(
    componentListQueryOptions({ studyId: params.study }),
  );
  return (
    <div>
      <RouteHeader
        title="Study configuration"
        description="Configure your study and everything related to it."
      />
      <div className="flex max-w-7xl flex-col gap-14 p-6 pb-12">
        <GeneralCard study={study} isLoading={studyQuery.isLoading} />
        <ParticipationCriteriaCard
          study={study}
          isLoading={studyQuery.isLoading}
        />
        <EnrollmentCard study={study} isLoading={studyQuery.isLoading} />
        <ConsentCard study={study} isLoading={studyQuery.isLoading} />
        <ComponentsCard
          components={components}
          isLoading={componentQuery.isLoading}
        />
      </div>
    </div>
  );
};

export const Route = createFileRoute(
  "/(dashboard)/$group/$study/configuration/",
)({
  component: StudyConfigurationRoute,
});
