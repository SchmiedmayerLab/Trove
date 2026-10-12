// This source file is part of the Trove open-source project
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { Field, Input } from "@schmiedmayerlab/grove-design-system";
import { ConsentEditor } from "@/components/interfaces/ConsentEditor/ConsentEditor";
import { FieldLabel } from "@/components/ui/FieldLabel";
import { enhanceField } from "@/utils/enhanceField";
import { LocaleSuffix } from "./LocaleSuffix";
import type { ConsentForm as ConsentFormType } from "../lib/useConsentForm";

export const ConsentForm = ({
  form,
  locale,
  onSubmit,
}: {
  form: ConsentFormType;
  locale: string;
  onSubmit: () => void;
}) => (
  <form onSubmit={onSubmit} className="py-6">
    <Field
      control={form.control}
      name="title"
      checkEmptyError
      label={
        <FieldLabel
          title={
            <>
              Consent title
              <LocaleSuffix locale={locale} />
            </>
          }
          description="Shown to participants at the top of the consent screen."
        />
      }
      className="border-border-tertiary border-b px-6 pb-6"
      render={({ field }) => (
        <Input placeholder="Study Consent Form" {...enhanceField(field)} />
      )}
    />
    <Field
      control={form.control}
      name="content"
      checkEmptyError
      label={
        <FieldLabel
          title={
            <>
              Consent document
              <LocaleSuffix locale={locale} />
            </>
          }
          description="Write the study information and the responses participants need to provide."
        />
      }
      className="px-6 pt-6"
      render={({ field }) => (
        <ConsentEditor
          key={locale}
          value={field.value}
          onChange={field.onChange}
          onBlur={field.onBlur}
        />
      )}
    />
  </form>
);
