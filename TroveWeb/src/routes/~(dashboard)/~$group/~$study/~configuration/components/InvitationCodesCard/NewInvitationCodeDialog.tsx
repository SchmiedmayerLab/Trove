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
  DialogTrigger,
  Field,
  Input,
  toast,
  useForm,
} from "@schmiedmayerlab/grove-design-system";
import { Ticket } from "lucide-react";
import { type ReactNode } from "react";
import { z } from "zod";
import { FeaturedIconContainer } from "@/components/ui/FeaturedIconContainer";
import { FieldLabel } from "@/components/ui/FieldLabel";
import { useCreateInvitationCodesMutation } from "@/lib/queries/invitationCode";
import { enhanceField } from "@/utils/enhanceField";

const formSchema = z.object({
  count: z.number().int().min(1).max(50),
  expiresAt: z.string().optional(),
});

interface NewInvitationCodeDialogProps {
  studyId: string;
  children: ReactNode;
}

export const NewInvitationCodeDialog = ({
  studyId,
  children,
}: NewInvitationCodeDialogProps) => {
  const createCodes = useCreateInvitationCodesMutation();
  const form = useForm({
    formSchema,
    defaultValues: { count: 1, expiresAt: "" },
  });

  const handleSubmit = form.handleSubmit(({ count, expiresAt }) => {
    createCodes.mutate(
      {
        path: { studyId },
        body: {
          count,
          ...(expiresAt && {
            expiresAt: new Date(expiresAt)
              .toISOString()
              .replace(/\.\d{3}Z$/, "Z"),
          }),
        },
      },
      {
        onSuccess: (codes) => {
          toast.success(
            `Generated ${codes.length} invitation code${codes.length === 1 ? "" : "s"}`,
          );
          form.reset({ count: 1, expiresAt: "" });
        },
      },
    );
  });

  return (
    <Dialog>
      <DialogTrigger asChild>{children}</DialogTrigger>
      <DialogContent className="max-w-md">
        <form onSubmit={handleSubmit}>
          <DialogHeader className="items-center sm:items-start">
            <FeaturedIconContainer
              icon={Ticket}
              className="border-border-tertiary mb-4 size-8 rounded-lg shadow-xs"
            />
            <DialogTitle>Generate invitation codes</DialogTitle>
            <DialogDescription>
              Each generated code can be used to enroll a single participant.
            </DialogDescription>
          </DialogHeader>
          <div className="flex flex-col gap-4 pt-4">
            <Field
              control={form.control}
              name="count"
              label={
                <FieldLabel
                  title="How many?"
                  description="Generate between 1 and 50 codes per batch."
                />
              }
              render={({ field }) => (
                <Input
                  type="number"
                  min={1}
                  max={50}
                  {...enhanceField(field, { valueAsNumber: true })}
                />
              )}
            />
            <Field
              control={form.control}
              name="expiresAt"
              label={
                <FieldLabel
                  title="Expires at (optional)"
                  description="Codes become unusable after this date. Leave blank for no expiry."
                />
              }
              render={({ field }) => (
                <Input type="datetime-local" {...enhanceField(field)} />
              )}
            />
          </div>
          <DialogFooter>
            <Button
              type="submit"
              variant="default"
              size="sm"
              isPending={createCodes.isPending}
            >
              Generate
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
};
