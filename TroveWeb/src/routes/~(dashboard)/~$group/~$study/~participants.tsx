//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { DataTable } from "@schmiedmayerlab/grove-design-system";
import { useQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { createColumnHelper } from "@tanstack/react-table";
import { Card } from "@/components/ui/Card";
import { RouteHeader } from "@/components/ui/RouteHeader";
import type { EnrollmentResponse } from "@/lib/api/generated/types.gen";
import { enrollmentListQueryOptions } from "@/lib/queries/enrollment";
import { cn } from "@/utils/cn";

const formatDateTime = (value?: string) => {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleString();
};

const columnHelper = createColumnHelper<EnrollmentResponse>();

const columns = [
  columnHelper.accessor("participantId", {
    id: "participantId",
    header: "Participant",
    cell: (cellContext) => (
      <span className="font-mono text-xs">{cellContext.getValue()}</span>
    ),
  }),
  columnHelper.accessor("currentRevision", {
    id: "currentRevision",
    header: "Revision",
    cell: (cellContext) => (
      <span className="tabular-nums">v{cellContext.getValue()}</span>
    ),
    maxSize: 100,
  }),
  columnHelper.accessor("enrolledAt", {
    id: "enrolledAt",
    header: "Enrolled",
    cell: (cellContext) => (
      <span className="text-text-secondary text-sm">
        {formatDateTime(cellContext.getValue())}
      </span>
    ),
  }),
  columnHelper.accessor("withdrawnAt", {
    id: "status",
    header: "Status",
    cell: (cellContext) => {
      const value = cellContext.getValue();
      return value ?
          <span className="text-text-tertiary text-sm">
            Withdrawn {formatDateTime(value)}
          </span>
        : <span className="text-text text-sm">Active</span>;
    },
  }),
  columnHelper.accessor("id", {
    id: "id",
    header: "Enrollment ID",
    cell: (cellContext) => (
      <span className="text-text-tertiary font-mono text-xs">
        {cellContext.getValue()}
      </span>
    ),
  }),
];

const ParticipantsRoute = () => {
  const params = Route.useParams();
  const { data: enrollments, isLoading } = useQuery(
    enrollmentListQueryOptions({ studyId: params.study }),
  );

  return (
    <div>
      <RouteHeader
        title="Participants"
        description="Everyone enrolled in this study, including past withdrawals."
      />
      <div className="flex max-w-7xl flex-col gap-6 p-6 pb-12">
        <Card className="overflow-hidden">
          <DataTable
            loading={isLoading}
            entityName="enrollments"
            columns={columns}
            data={enrollments ?? []}
            bordered={false}
            className={cn(
              "!bg-layer",
              "[&_th]:bg-fill-secondary",
              "[&_th:last-of-type_button]:!hidden",
            )}
          />
        </Card>
      </div>
    </div>
  );
};

export const Route = createFileRoute("/(dashboard)/$group/$study/participants")(
  {
    component: ParticipantsRoute,
  },
);
