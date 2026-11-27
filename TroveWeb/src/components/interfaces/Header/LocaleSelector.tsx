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
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DropdownMenuItem,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuSeparator,
  Field,
  Input,
  useForm,
  useOpenState,
} from "@schmiedmayerlab/grove-design-system";
import { useQuery } from "@tanstack/react-query";
import { useParams } from "@tanstack/react-router";
import { Languages, X } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { z } from "zod";
import { FeaturedIconContainer } from "@/components/ui/FeaturedIconContainer";
import { FieldLabel } from "@/components/ui/FieldLabel";
import type { StudyResponse } from "@/lib/api/generated/types.gen";
import { useLocale } from "@/lib/locale";
import { draftHeaders } from "@/lib/queries/draft";
import {
  studyResponseQueryOptions,
  useUpdateStudyMutation,
} from "@/lib/queries/study";
import {
  HeaderSelector,
  HeaderSelectorMenuItem,
  HeaderSelectorMenuLabel,
} from "./HeaderSelector";

const LOCALE_PATTERN = /^[a-z]{2}-[A-Z]{2}$/;

const addLocaleSchema = z.object({
  locale: z
    .string()
    .min(1, "Enter a locale code")
    .regex(LOCALE_PATTERN, "Use format: en-US"),
});

interface AddLocaleDialogContentProps {
  studyId: string;
  existingLocales: string[];
  draftRevision: string;
  onSuccess?: () => void;
}

const AddLocaleDialogContent = ({
  studyId,
  existingLocales,
  draftRevision,
  onSuccess,
}: AddLocaleDialogContentProps) => {
  const { setLocale } = useLocale();
  const updateStudy = useUpdateStudyMutation();
  const form = useForm({
    formSchema: addLocaleSchema,
    defaultValues: { locale: "" },
  });

  const handleSubmit = form.handleSubmit(async ({ locale }) => {
    if (existingLocales.includes(locale)) {
      form.setError("locale", { message: "Already added" });
      return;
    }
    await updateStudy.mutateAsync({
      path: { studyId },
      headers: draftHeaders(draftRevision),
      body: { locales: [...existingLocales, locale] },
    });
    setLocale(locale);
    onSuccess?.();
  });

  return (
    <DialogContent className="max-w-md">
      <form onSubmit={handleSubmit}>
        <DialogHeader className="items-center sm:items-start">
          <FeaturedIconContainer
            icon={Languages}
            className="border-border-tertiary mb-4 size-8 rounded-lg shadow-xs"
          />
          <DialogTitle>Add a locale</DialogTitle>
          <DialogDescription>
            Add a language-region locale for the study's consent and
            informational documents. Study details and questionnaires keep their
            languages in their own content.
          </DialogDescription>
        </DialogHeader>
        <div className="pt-4">
          <Field
            control={form.control}
            name="locale"
            label={<FieldLabel title="Locale code" />}
            render={({ field }) => (
              <Input placeholder="e.g. de-DE" {...field} />
            )}
          />
        </div>
        <DialogFooter>
          <Button
            type="submit"
            variant="default"
            size="sm"
            isPending={updateStudy.isPending}
          >
            Add locale
          </Button>
        </DialogFooter>
      </form>
    </DialogContent>
  );
};

const LocaleSelectorContent = ({ studyId }: { studyId: string }) => {
  const { locale: activeLocale, setLocale } = useLocale();
  const addLocaleDialog = useOpenState();
  const deleteDialog = useOpenState();
  const [pendingDeleteLocale, setPendingDeleteLocale] = useState<{
    locale: string;
    study: StudyResponse;
  }>();
  const [pendingAddStudy, setPendingAddStudy] = useState<StudyResponse>();
  // The locale dialogs have no trigger of their own, so focus returns to the
  // selector when one closes. A dialog chosen in the menu opens once the menu
  // content has unmounted, so no closing menu can take focus from the selector.
  const dialogAfterMenuRef = useRef<() => void>(undefined);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const isDialogOpen = addLocaleDialog.isOpen || deleteDialog.isOpen;
  const wasDialogOpenRef = useRef(false);
  useEffect(() => {
    if (wasDialogOpenRef.current && !isDialogOpen) triggerRef.current?.focus();
    wasDialogOpenRef.current = isDialogOpen;
  }, [isDialogOpen]);
  const updateStudy = useUpdateStudyMutation();

  const { data: study } = useQuery({
    ...studyResponseQueryOptions({ studyId }),
    enabled: !!studyId,
  });

  const locales = study?.locales ?? ["en-US"];

  const handleRemove = () => {
    if (!pendingDeleteLocale) return;
    const newLocales = pendingDeleteLocale.study.locales.filter(
      (locale) => locale !== pendingDeleteLocale.locale,
    );
    updateStudy.mutate(
      {
        path: { studyId },
        headers: draftHeaders(pendingDeleteLocale.study.draftRevision),
        body: { locales: newLocales },
      },
      {
        onSuccess: () => {
          if (activeLocale === pendingDeleteLocale.locale) {
            setLocale(newLocales[0] ?? "en-US");
          }
          deleteDialog.close();
          setPendingDeleteLocale(undefined);
        },
        onError: () => {
          deleteDialog.close();
          setPendingDeleteLocale(undefined);
        },
      },
    );
  };

  return (
    <>
      <HeaderSelector
        triggerRef={triggerRef}
        onOpenChange={(open) => {
          // A dialog chosen before the menu reopened no longer applies.
          if (open) dialogAfterMenuRef.current = undefined;
        }}
        onMenuUnmount={() => {
          dialogAfterMenuRef.current?.();
          dialogAfterMenuRef.current = undefined;
        }}
        selectedItem={{
          title: (
            <>
              <span className="text-text-secondary">Documents</span>{" "}
              {activeLocale}
            </>
          ),
        }}
      >
        <HeaderSelectorMenuLabel>
          Consent and informational document locales
        </HeaderSelectorMenuLabel>
        <DropdownMenuRadioGroup
          aria-label="Document locales"
          value={activeLocale}
          onValueChange={setLocale}
        >
          {locales.map((locale) => (
            <div key={locale} className="flex items-center gap-1">
              <DropdownMenuRadioItem
                value={locale}
                className="flex-1 py-2 pl-10 [&>span:first-child]:left-3.5"
              >
                {locale}
              </DropdownMenuRadioItem>
              {locales.length > 1 && (
                <DropdownMenuItem
                  aria-label={`Remove ${locale}`}
                  className="text-text-tertiary p-2!"
                  onSelect={() => {
                    if (!study) return;
                    dialogAfterMenuRef.current = () => {
                      setPendingDeleteLocale({ locale, study });
                      deleteDialog.open();
                    };
                  }}
                >
                  <X />
                </DropdownMenuItem>
              )}
            </div>
          ))}
        </DropdownMenuRadioGroup>
        <DropdownMenuSeparator />
        <HeaderSelectorMenuItem
          icon="plus"
          className="text-text-tertiary"
          onSelect={() => {
            if (!study) return;
            dialogAfterMenuRef.current = () => {
              setPendingAddStudy(study);
              addLocaleDialog.open();
            };
          }}
        >
          Add locale
        </HeaderSelectorMenuItem>
      </HeaderSelector>
      <Dialog
        open={addLocaleDialog.isOpen}
        onOpenChange={addLocaleDialog.setIsOpen}
      >
        {pendingAddStudy && (
          <AddLocaleDialogContent
            studyId={studyId}
            existingLocales={pendingAddStudy.locales}
            draftRevision={pendingAddStudy.draftRevision}
            onSuccess={addLocaleDialog.close}
          />
        )}
      </Dialog>
      <ConfirmDeleteDialog
        open={deleteDialog.isOpen}
        onOpenChange={deleteDialog.setIsOpen}
        entityName="locale"
        itemName={pendingDeleteLocale?.locale}
        onDelete={handleRemove}
      />
    </>
  );
};

export const LocaleSelector = () => {
  const params = useParams({ strict: false });

  if (!params.study) {
    return null;
  }

  return <LocaleSelectorContent studyId={params.study} />;
};
