//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import {
  Button,
  Field,
  Input,
  Textarea,
} from "@schmiedmayerlab/grove-design-system";
import {
  ChevronDown,
  FileSignature,
  ListChecks,
  ToggleLeft,
} from "lucide-react";
import { useRef } from "react";
import { FieldLabel } from "@/components/ui/FieldLabel";
import { enhanceField } from "@/utils/enhanceField";
import { LocaleSuffix } from "./LocaleSuffix";
import type { ConsentForm as ConsentFormType } from "../lib/useConsentForm";

const SNIPPETS = {
  toggle: `<toggle id="agree" expected-value="true">
  I agree to the terms above.
</toggle>`,
  select: `<select id="preference" expected-value="*">
  How would you like to be contacted?
  <option id="email">Email</option>
  <option id="phone">Phone</option>
</select>`,
  signature: `<signature id="participant-signature" />`,
} as const;

type SnippetKey = keyof typeof SNIPPETS;

interface InsertButtonProps {
  label: string;
  icon: React.ComponentType<{ className?: string }>;
  onInsert: () => void;
}

const InsertButton = ({ label, icon: Icon, onInsert }: InsertButtonProps) => (
  <Button
    type="button"
    variant="outline"
    size="sm"
    className="!h-8 text-sm"
    onClick={onInsert}
  >
    <Icon className="size-3.5 opacity-80" />
    {label}
  </Button>
);

interface ConsentFormProps {
  form: ConsentFormType;
  locale: string;
  onSubmit: () => void;
}

export const ConsentForm = ({ form, locale, onSubmit }: ConsentFormProps) => {
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  const insertSnippet = (key: SnippetKey) => {
    const snippet = SNIPPETS[key];
    const current = form.getValues("content");
    const textarea = textareaRef.current;
    const start = textarea?.selectionStart ?? current.length;
    const end = textarea?.selectionEnd ?? current.length;
    const needsLeadingNewline = start > 0 && current[start - 1] !== "\n";
    const insertion = `${needsLeadingNewline ? "\n" : ""}${snippet}\n`;
    const next = current.slice(0, start) + insertion + current.slice(end);
    form.setValue("content", next, {
      shouldDirty: true,
      shouldTouch: true,
      shouldValidate: true,
    });
    requestAnimationFrame(() => {
      const node = textareaRef.current;
      if (!node) return;
      node.focus();
      const caret = start + insertion.length;
      node.setSelectionRange(caret, caret);
    });
  };

  return (
    <form onSubmit={onSubmit} className="py-6">
      <Field
        control={form.control}
        name="title"
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
        className="border-border-tertiary border-b px-6"
        render={({ field }) => (
          <Input placeholder="Study Consent Form" {...enhanceField(field)} />
        )}
      />
      <Field
        control={form.control}
        name="content"
        label={
          <FieldLabel
            title={
              <>
                Consent document
                <LocaleSuffix locale={locale} />
              </>
            }
            description="Markdown body. Use the buttons below to add interactive elements (toggles, selects, signature) the iOS app will render natively."
          />
        }
        className="px-6 pt-6"
        render={({ field }) => {
          const enhanced = enhanceField(field);
          return (
            <div className="flex flex-col gap-2">
              <div className="flex flex-wrap items-center gap-2">
                <span className="text-text-tertiary mr-1 text-xs tracking-wide uppercase">
                  Insert
                </span>
                <InsertButton
                  label="Toggle"
                  icon={ToggleLeft}
                  onInsert={() => insertSnippet("toggle")}
                />
                <InsertButton
                  label="Select"
                  icon={ListChecks}
                  onInsert={() => insertSnippet("select")}
                />
                <InsertButton
                  label="Signature"
                  icon={FileSignature}
                  onInsert={() => insertSnippet("signature")}
                />
                <details className="group ml-auto text-xs">
                  <summary className="text-text-tertiary hover:text-text flex cursor-pointer items-center gap-1">
                    Syntax help
                    <ChevronDown className="size-3 transition-transform group-open:rotate-180" />
                  </summary>
                  <pre className="bg-fill-secondary text-text-secondary mt-2 max-w-md overflow-x-auto rounded-md p-3 text-xs">
                    {`<toggle id="..." expected-value="true">label</toggle>
<select id="..." expected-value="*">
  question
  <option id="...">label</option>
</select>
<signature id="..." />`}
                  </pre>
                </details>
              </div>
              <Textarea
                ref={textareaRef}
                rows={20}
                spellCheck
                className="font-mono text-sm"
                placeholder={`# Consent\n\nBy participating in this study you agree...\n\n<toggle id="agree" expected-value="true">I agree</toggle>`}
                {...enhanced}
              />
            </div>
          );
        }}
      />
    </form>
  );
};
