//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import {
  ConfirmDeleteDialog,
  Dialog,
  DropdownMenuSeparator,
  Skeleton,
  useOpenState,
} from "@schmiedmayerlab/grove-design-system";
import { useQuery } from "@tanstack/react-query";
import { useNavigate, useParams } from "@tanstack/react-router";
import { X } from "lucide-react";
import { useState } from "react";
import { getStudiesByStudyId } from "@/lib/api/generated/sdk.gen";
import { draftHeaders } from "@/lib/queries/draft";
import { onMutationError } from "@/lib/queries/mutationCallbacks";
import {
  studyListQueryOptions,
  useDeleteStudyMutation,
} from "@/lib/queries/study";
import {
  HeaderSelector,
  HeaderSelectorMenuItem,
  HeaderSelectorMenuLabel,
} from "./HeaderSelector";
import { HeaderSelectorSkeleton } from "./HeaderSelectorSkeleton";
import { NewStudyDialogContent } from "../NewStudyDialog";

export const StudySelector = () => {
  const { group, study: studyId } = useParams({ strict: false });
  const navigate = useNavigate();
  const { data: studies } = useQuery({
    ...studyListQueryOptions({ groupId: group ?? "" }),
    enabled: !!group,
  });
  const selectedStudy = studies?.find((study) => study.id === studyId);

  const newStudyDialog = useOpenState();
  const deleteDialog = useOpenState();
  const [pendingDelete, setPendingDelete] = useState<{
    id: string;
    title: string;
    draftRevision: string;
  }>();
  const deleteStudy = useDeleteStudyMutation();

  if (!studyId || !group) {
    return null;
  }

  if (!studies) {
    return <HeaderSelectorSkeleton hasIcon={false} />;
  }

  const title = selectedStudy?.title ?? (
    <Skeleton className="bg-fill-tertiary h-4 w-20 rounded-sm" />
  );

  const handleDelete = async () => {
    if (!pendingDelete) return;
    const removingActive = pendingDelete.id === studyId;
    await deleteStudy.mutateAsync({
      path: { studyId: pendingDelete.id },
      headers: draftHeaders(pendingDelete.draftRevision),
    });
    deleteDialog.close();
    setPendingDelete(undefined);
    if (removingActive) {
      await navigate({ to: "/$group", params: { group } });
    }
  };

  return (
    <>
      <HeaderSelector selectedItem={{ title }}>
        <HeaderSelectorMenuLabel>Studies</HeaderSelectorMenuLabel>
        {studies.map((study) => (
          <HeaderSelectorMenuItem
            key={study.id}
            linkOptions={{
              to: "/$group/$study",
              params: {
                group,
                study: study.id,
              },
            }}
          >
            <span className="flex-1">{study.title}</span>
            <button
              type="button"
              className="text-text-tertiary hover:text-text -mr-1 rounded p-0.5"
              aria-label={`Delete ${study.title}`}
              onClick={(event) => {
                event.preventDefault();
                event.stopPropagation();
                void getStudiesByStudyId({
                  path: { studyId: study.id },
                  throwOnError: true,
                })
                  .then(({ data }) => {
                    setPendingDelete({
                      id: data.id,
                      title:
                        Object.values(data.details).at(0)?.title ?? study.title,
                      draftRevision: data.draftRevision,
                    });
                    deleteDialog.open();
                  })
                  .catch(onMutationError("Error loading study for deletion"));
              }}
            >
              <X className="size-3.5" />
            </button>
          </HeaderSelectorMenuItem>
        ))}
        <DropdownMenuSeparator />
        <HeaderSelectorMenuItem
          icon="plus"
          className="text-text-tertiary"
          onSelect={newStudyDialog.open}
        >
          Add study
        </HeaderSelectorMenuItem>
      </HeaderSelector>
      <Dialog
        open={newStudyDialog.isOpen}
        onOpenChange={newStudyDialog.setIsOpen}
      >
        <NewStudyDialogContent
          groupId={group}
          onSuccess={newStudyDialog.close}
        />
      </Dialog>
      <ConfirmDeleteDialog
        open={deleteDialog.isOpen}
        onOpenChange={deleteDialog.setIsOpen}
        entityName="study"
        itemName={pendingDelete?.title}
        onDelete={handleDelete}
      />
    </>
  );
};
