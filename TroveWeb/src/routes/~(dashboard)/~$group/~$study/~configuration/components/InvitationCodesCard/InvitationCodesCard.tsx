//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { Button, DataTable } from "@schmiedmayerlab/grove-design-system";
import { useQuery } from "@tanstack/react-query";
import { createColumnHelper } from "@tanstack/react-table";
import { Plus } from "lucide-react";
import { Card, CardHeader } from "@/components/ui/Card";
import type { InvitationCodeResponse } from "@/lib/api/generated/types.gen";
import { invitationCodeListQueryOptions } from "@/lib/queries/invitationCode";
import { cn } from "@/utils/cn";
import { InvitationCodesCardRowActions } from "./InvitationCodesCardRow";
import { NewInvitationCodeDialog } from "./NewInvitationCodeDialog";

const formatExpiry = (value?: string) => {
  if (!value) return "Never";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleString();
};

interface InvitationCodesCardProps {
  studyId: string;
}

export const InvitationCodesCard = ({ studyId }: InvitationCodesCardProps) => {
  const { data: codes, isLoading } = useQuery(
    invitationCodeListQueryOptions({ studyId }),
  );

  const columnHelper = createColumnHelper<InvitationCodeResponse>();
  const columns = [
    columnHelper.accessor("code", {
      id: "code",
      header: "Code",
      cell: (cellContext) => (
        <span className="font-mono text-sm">{cellContext.getValue()}</span>
      ),
    }),
    columnHelper.accessor("used", {
      id: "status",
      header: "Status",
      cell: (cellContext) =>
        cellContext.getValue() ?
          <span className="text-text-tertiary text-sm">Used</span>
        : <span className="text-text text-sm">Available</span>,
      maxSize: 120,
    }),
    columnHelper.accessor("expiresAt", {
      id: "expiresAt",
      header: "Expires",
      cell: (cellContext) => (
        <span className="text-text-secondary text-sm">
          {formatExpiry(cellContext.getValue())}
        </span>
      ),
    }),
    columnHelper.accessor("id", {
      id: "actions",
      header: "Actions",
      cell: (cellContext) => (
        <InvitationCodesCardRowActions
          studyId={studyId}
          codeId={cellContext.getValue()}
          used={cellContext.row.original.used}
        />
      ),
      minSize: 50,
      maxSize: 50,
    }),
  ];

  return (
    <Card className="overflow-hidden">
      <CardHeader
        title="Invitation codes"
        description="Generate codes to share with participants who should have access."
      >
        <NewInvitationCodeDialog studyId={studyId}>
          <Button size="sm" variant="outline" className="!h-8 text-sm">
            <Plus className="size-3.5 opacity-80" />
            Generate codes
          </Button>
        </NewInvitationCodeDialog>
      </CardHeader>
      <DataTable
        loading={isLoading}
        entityName="invitation codes"
        columns={columns}
        data={codes ?? []}
        bordered={false}
        className={cn(
          "!bg-layer",
          "[&_th]:bg-fill-secondary",
          "[&_th:last-of-type_button]:!hidden",
        )}
      />
    </Card>
  );
};
