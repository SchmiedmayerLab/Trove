//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import {
  Button,
  ConfirmDeleteDialog,
  useOpenState,
} from "@schmiedmayerlab/grove-design-system";
import { Trash } from "lucide-react";
import { useDeleteInvitationCodeMutation } from "@/lib/queries/invitationCode";

interface InvitationCodesCardRowActionsProps {
  studyId: string;
  codeId: string;
  used: boolean;
}

export const InvitationCodesCardRowActions = ({
  studyId,
  codeId,
  used,
}: InvitationCodesCardRowActionsProps) => {
  const deleteDialog = useOpenState();
  const deleteCode = useDeleteInvitationCodeMutation();

  return (
    <>
      <div className="flex-center h-full">
        <Button
          variant="ghost"
          size={null}
          className="size-8 rounded-sm p-2"
          aria-label="Delete invitation code"
          disabled={used || deleteCode.isPending}
          onClick={deleteDialog.open}
        >
          <Trash className="size-3.5 opacity-80" />
        </Button>
      </div>
      <ConfirmDeleteDialog
        open={deleteDialog.isOpen}
        onOpenChange={deleteDialog.setIsOpen}
        entityName="invitation code"
        onDelete={async () => {
          await deleteCode.mutateAsync({
            path: { studyId, codeId },
          });
          deleteDialog.close();
        }}
      />
    </>
  );
};
