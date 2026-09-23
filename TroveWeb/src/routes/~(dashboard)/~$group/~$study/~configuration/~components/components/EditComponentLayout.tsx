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
import { useNavigate, useParams } from "@tanstack/react-router";
import { type ReactNode, useState } from "react";
import { RouteHeader, RouteHeaderBackLink } from "@/components/ui/RouteHeader";
import {
  readComponentDeletionSnapshot,
  useDeleteComponentMutation,
} from "@/lib/queries/component";
import { draftHeaders } from "@/lib/queries/draft";
import { onMutationError } from "@/lib/queries/mutationCallbacks";
import { ScheduleDialog } from "./ScheduleDialog";

interface EditComponentLayoutProps {
  children: ReactNode;
  saveButton: ReactNode;
  showScheduleButton?: boolean;
}

export const EditComponentLayout = ({
  children,
  saveButton,
  showScheduleButton = true,
}: EditComponentLayoutProps) => {
  const params = useParams({
    from: "/(dashboard)/$group/$study/configuration/components/$componentType/$component",
  });
  const navigate = useNavigate();
  const deleteDialog = useOpenState();
  const deleteComponent = useDeleteComponentMutation();
  const [deletion, setDeletion] =
    useState<Awaited<ReturnType<typeof readComponentDeletionSnapshot>>>();

  const handleDelete = async () => {
    if (!deletion) return;
    await deleteComponent.mutateAsync({
      headers: draftHeaders(deletion.draftRevision),
      path: {
        studyId: params.study,
        componentId: params.component,
      },
    });
    await navigate({
      to: "/$group/$study/configuration/components",
      params: { group: params.group, study: params.study },
    });
    deleteDialog.close();
  };

  return (
    <>
      <div>
        <RouteHeader
          title="Edit component"
          description="Configure the details of your component."
          accessoryLeft={
            <RouteHeaderBackLink
              to="/$group/$study/configuration/components"
              params={{ group: params.group, study: params.study }}
            />
          }
          accessoryRight={
            <div className="flex items-center gap-6">
              <Button
                variant="ghost"
                size="sm"
                className="text-sm"
                onClick={() => {
                  void readComponentDeletionSnapshot(
                    params.study,
                    params.component,
                  )
                    .then((snapshot) => {
                      setDeletion(snapshot);
                      deleteDialog.open();
                    })
                    .catch(
                      onMutationError("Error loading component for deletion"),
                    );
                }}
              >
                Delete
              </Button>
              {showScheduleButton && <ScheduleDialog />}
              {saveButton}
            </div>
          }
        />
        {children}
      </div>
      <ConfirmDeleteDialog
        open={deleteDialog.isOpen}
        onOpenChange={deleteDialog.setIsOpen}
        entityName="component"
        itemName={deletion?.name}
        onDelete={handleDelete}
      />
    </>
  );
};
