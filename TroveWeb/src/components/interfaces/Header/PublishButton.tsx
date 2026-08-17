//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import {
  Button,
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  toast,
  useOpenState,
} from "@schmiedmayerlab/grove-design-system";
import { useQuery } from "@tanstack/react-query";
import { useParams } from "@tanstack/react-router";
import { Rocket } from "lucide-react";
import {
  publishedStudiesQueryOptions,
  usePublishStudyMutation,
} from "@/lib/queries/study";
import { FeaturedIconContainer } from "../../ui/FeaturedIconContainer";

export const PublishButton = () => {
  const { study: studyId } = useParams({ strict: false });
  const publishStudy = usePublishStudyMutation();
  const confirmDialog = useOpenState();
  const { data: published } = useQuery({
    ...publishedStudiesQueryOptions({ studyId: studyId ?? "" }),
    enabled: !!studyId,
  });

  if (!studyId) return null;

  const latestRevision =
    published?.length ?
      Math.max(...published.map((entry) => entry.revision))
    : undefined;

  const nextRevision = (latestRevision ?? 0) + 1;

  const onConfirm = () => {
    publishStudy.mutate(
      { path: { studyId } },
      {
        onSuccess: (data) => {
          toast.success(`Study published (v${data.revision})`);
          confirmDialog.close();
        },
      },
    );
  };

  return (
    <>
      <Button size="sm" variant="default" onClick={confirmDialog.open}>
        Publish
      </Button>
      <Dialog
        open={confirmDialog.isOpen}
        onOpenChange={confirmDialog.setIsOpen}
      >
        <DialogContent className="max-w-md">
          <DialogHeader className="items-center sm:items-start">
            <FeaturedIconContainer
              icon={Rocket}
              className="border-border-tertiary mb-4 size-8 rounded-lg shadow-xs"
            />
            <DialogTitle>Publish study?</DialogTitle>
            <DialogDescription>
              {latestRevision !== undefined ?
                `This builds the study bundle and creates revision v${nextRevision} (current: v${latestRevision}).`
              : `This builds the study bundle and creates the first published revision (v${nextRevision}).`
              }
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button
              variant="outline"
              size="sm"
              onClick={confirmDialog.close}
              disabled={publishStudy.isPending}
            >
              Cancel
            </Button>
            <Button
              variant="default"
              size="sm"
              onClick={onConfirm}
              isPending={publishStudy.isPending}
            >
              Publish v{nextRevision}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
};
