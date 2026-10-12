// This source file is part of the Trove open-source project
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import {
  Button,
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
  DialogFooter,
  Input,
} from "@schmiedmayerlab/grove-design-system";
import { Pencil, Trash2 } from "lucide-react";
import { useId, useState } from "react";

export const EditConsentID = ({
  id,
  option = false,
  onRename,
}: {
  id: string;
  option?: boolean;
  onRename: (id: string) => void;
}) => {
  const [open, setOpen] = useState(false);
  const [draft, setDraft] = useState(id);
  const [error, setError] = useState<string>();
  const inputId = useId();
  const rename = () => {
    try {
      onRename(draft);
      setOpen(false);
    } catch (cause) {
      setError(
        cause instanceof Error ? cause.message : "The ID could not be changed.",
      );
    }
  };
  const label = option ? "Option ID" : "Field ID";
  const actionLabel = option ? "Edit option ID" : "Edit field ID";
  return (
    <>
      <Button
        type="button"
        variant="ghost"
        size="sm"
        className="text-text-secondary h-auto max-w-full gap-2 px-2 py-1 font-mono text-xs"
        aria-label={`${actionLabel}: ${id}`}
        onClick={() => {
          setDraft(id);
          setError(undefined);
          setOpen(true);
        }}
      >
        <span className="truncate">ID: {id}</span>
        <Pencil className="size-3 shrink-0" />
      </Button>
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>{actionLabel}</DialogTitle>
            <DialogDescription>
              IDs identify consent responses. Keep matching IDs across
              translations.
              {option &&
                " Default and required-response references update with this option."}{" "}
              This changes the current draft, not previously accepted consent.
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-2 py-5">
            <label htmlFor={inputId} className="text-sm font-medium">
              {label}
            </label>
            <Input
              id={inputId}
              value={draft}
              className="font-mono"
              aria-invalid={!!error}
              aria-describedby={error ? `${inputId}-error` : undefined}
              onChange={(event) => {
                setDraft(event.target.value);
                setError(undefined);
              }}
              onKeyDown={(event) => {
                if (event.key === "Enter") {
                  event.preventDefault();
                  rename();
                }
              }}
            />
            {error && (
              <p
                id={`${inputId}-error`}
                role="alert"
                className="text-destructive text-sm"
              >
                {error}
              </p>
            )}
          </div>
          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              onClick={() => setOpen(false)}
            >
              Cancel
            </Button>
            <Button type="button" onClick={rename} disabled={draft === id}>
              Apply ID
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
};

export const DeleteConsentField = ({
  kind,
  id,
  onDelete,
}: {
  kind: string;
  id?: string;
  onDelete: () => void;
}) => {
  const [open, setOpen] = useState(false);
  return (
    <>
      <Button
        type="button"
        variant="ghost"
        size="sm"
        className="text-destructive hover:bg-destructive/10 hover:text-destructive gap-2"
        aria-label={`Delete ${kind.toLowerCase()}`}
        onClick={() => setOpen(true)}
      >
        <Trash2 className="size-4" />
        <span>Delete</span>
      </Button>
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>Delete {kind.toLowerCase()}?</DialogTitle>
            <DialogDescription>
              Remove <span className="font-mono font-medium">{id}</span> and its
              wording from this draft? This takes effect when you save.
              Previously published consent and participant responses are not
              changed.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter className="pt-5">
            <Button
              type="button"
              variant="outline"
              onClick={() => setOpen(false)}
            >
              Cancel
            </Button>
            <Button
              type="button"
              variant="destructive"
              onClick={() => {
                onDelete();
                setOpen(false);
              }}
            >
              Delete
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
};
