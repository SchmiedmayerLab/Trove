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
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
  useOpenState,
} from "@schmiedmayerlab/grove-design-system";
import { Link, useParams } from "@tanstack/react-router";
import { Edit, Ellipsis, Trash } from "lucide-react";
import { useState } from "react";
import { FeaturedIconContainer } from "@/components/ui/FeaturedIconContainer";
import type { ComponentType } from "@/lib/api/types";
import {
  readComponentDeletionSnapshot,
  useDeleteComponentMutation,
} from "@/lib/queries/component";
import { draftHeaders } from "@/lib/queries/draft";
import { onMutationError } from "@/lib/queries/mutationCallbacks";
import { cn } from "@/utils/cn";
import type { getComponentLabel } from "../../lib/formatComponent";

interface ComponentsCardRowLabelProps {
  label: ReturnType<typeof getComponentLabel>;
  componentId: string;
  componentType: ComponentType;
}

export const ComponentsCardRowLabel = ({
  label,
  componentId,
  componentType,
}: ComponentsCardRowLabelProps) => {
  const { group, study } = useParams({ strict: false });
  if (!group || !study) return null;

  return (
    <div className="flex items-center gap-2">
      <div>
        <FeaturedIconContainer
          className={cn(
            "[--container-radius:var(--radius-md)]",
            "border-border-tertiary size-6 shadow-xs",
          )}
        >
          <label.icon
            className={cn("size-full rounded p-[3px]", label.className)}
          />
        </FeaturedIconContainer>
      </div>
      <Link
        to="/$group/$study/configuration/components/$componentType/$component"
        params={{
          group,
          study,
          componentType,
          component: componentId,
        }}
        className="focus-ring hover:text-text decoration-text-tertiary min-w-0 truncate rounded-sm underline-offset-2 hover:underline"
      >
        {label.text}
      </Link>
    </div>
  );
};

interface ComponentsCardRowActionsProps {
  componentId: string;
  componentType: ComponentType;
}

export const ComponentsCardRowActions = ({
  componentId,
  componentType,
}: ComponentsCardRowActionsProps) => {
  const { group, study } = useParams({ strict: false });
  const deleteDialog = useOpenState();
  const deleteComponent = useDeleteComponentMutation();
  const [deletion, setDeletion] =
    useState<Awaited<ReturnType<typeof readComponentDeletionSnapshot>>>();

  if (!group || !study) return null;

  return (
    <>
      <div className="flex-center h-full">
        <DropdownMenu modal={false}>
          <DropdownMenuTrigger asChild>
            <Button
              variant="ghost"
              size={null}
              className="size-8 rounded-sm p-2"
            >
              <Ellipsis className="opacity-80" />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent side="left" align="start">
            <DropdownMenuItem asChild>
              <Link
                to="/$group/$study/configuration/components/$componentType/$component"
                params={{
                  group,
                  study,
                  componentType,
                  component: componentId,
                }}
              >
                <Edit className="size-3.5 opacity-80" />
                Edit
              </Link>
            </DropdownMenuItem>
            <DropdownMenuItem
              disabled={deleteComponent.isPending}
              onClick={() => {
                void readComponentDeletionSnapshot(study, componentId)
                  .then((snapshot) => {
                    setDeletion(snapshot);
                    deleteDialog.open();
                  })
                  .catch(
                    onMutationError("Error loading component for deletion"),
                  );
              }}
            >
              <Trash className="size-3.5 opacity-80" />
              Delete
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>
      <ConfirmDeleteDialog
        open={deleteDialog.isOpen}
        onOpenChange={deleteDialog.setIsOpen}
        entityName="component"
        itemName={deletion?.name}
        onDelete={async () => {
          if (!deletion) return;
          await deleteComponent.mutateAsync({
            headers: draftHeaders(deletion.draftRevision),
            path: {
              studyId: study,
              componentId,
            },
          });
          deleteDialog.close();
        }}
      />
    </>
  );
};
