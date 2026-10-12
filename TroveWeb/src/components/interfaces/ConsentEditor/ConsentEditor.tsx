// This source file is part of the Trove open-source project
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { Button, Textarea } from "@schmiedmayerlab/grove-design-system";
import {
  Code2,
  Eye,
  ListFilter,
  PenLine,
  Plus,
  Signature,
  ToggleLeft,
} from "lucide-react";
import { useState } from "react";
import { MarkdownEditor } from "@/components/ui/MarkdownEditor";
import {
  consentBlocks,
  newConsentField,
  replaceRange,
  setFieldAttribute,
  renameConsentID,
  type ConsentElement,
} from "./document";
import { DeleteConsentField, EditConsentID } from "./FieldActions";

type Mode = "Preview" | "Visual editor" | "Markdown";
interface Props {
  value: string;
  onChange: (value: string) => void;
  onBlur?: () => void;
}

const selectClass =
  "border-border bg-fill-secondary rounded-md border p-2 text-sm";

const fieldLabels: Record<string, string> = {
  toggle: "Toggle",
  select: "Selection",
  signature: "Signature block",
};

const fieldIcons: Record<string, typeof ToggleLeft> = {
  toggle: ToggleLeft,
  select: ListFilter,
  signature: Signature,
};
const modeIcons = { Preview: Eye, "Visual editor": PenLine, Markdown: Code2 };

const MarkdownBlock = ({
  value,
  onChange,
  readOnly,
  compact = false,
}: {
  value: string;
  onChange: (value: string) => void;
  readOnly: boolean;
  compact?: boolean;
}) => {
  // These constructs need extensions the shared editor does not support yet.
  // Keep their complete source rather than silently deleting them on the next edit.
  if (
    value.includes("![") ||
    value.includes("][") ||
    value
      .split("\n")
      .some((line) => line.trimStart().startsWith("[") && line.includes("]:"))
  ) {
    return (
      <div className="space-y-2">
        <p className="text-text-secondary text-sm">
          This block contains Markdown that requires source editing.
        </p>
        <Textarea
          aria-label="Preserved Markdown block"
          value={value}
          readOnly={readOnly}
          onChange={(event) => onChange(event.target.value)}
          rows={6}
        />
      </div>
    );
  }
  return (
    <MarkdownEditor
      value={value}
      onChange={onChange}
      readOnly={readOnly}
      className={compact ? "min-h-0 [&_.ProseMirror]:min-h-12" : undefined}
    />
  );
};

const FieldBlock = ({
  element,
  source,
  onChange,
  readOnly,
}: {
  element: ConsentElement;
  source: string;
  onChange: (value: string) => void;
  readOnly: boolean;
}) => {
  const options = element.children.filter((child) => child.name === "option");
  const label = {
    start: element.contentStart,
    end: element.children[0]?.start ?? element.contentEnd,
  };
  const editText = (range: { start: number; end: number }, value: string) =>
    onChange(replaceRange(source, range, value));
  const attribute = (name: "initial-value" | "expected-value", value: string) =>
    onChange(setFieldAttribute(source, element, name, value));
  const kind = fieldLabels[element.name];
  const Icon = fieldIcons[element.name];
  let requirement = element.attributes["expected-value"];
  if (requirement === "*") requirement = "Choose an option";
  else if (element.name === "toggle" && requirement) {
    requirement = requirement === "true" ? "Must be on" : "Must be off";
  }
  return (
    <section
      className="border-border bg-surface space-y-4 rounded-xl border p-5 shadow-xs"
      aria-label={`${kind}: ${element.attributes.id ?? "missing ID"}`}
    >
      {!readOnly && (
        <div className="border-border bg-fill-secondary -mx-5 -mt-5 flex flex-wrap items-center justify-between gap-3 rounded-t-xl border-b px-5 py-3">
          <div className="flex min-w-0 items-center gap-3">
            <div className="border-border bg-surface rounded-lg border p-2">
              <Icon className="text-text-secondary size-4" />
            </div>
            <div className="min-w-0">
              <h3 className="text-sm font-semibold">{kind}</h3>
              <EditConsentID
                id={element.attributes.id ?? ""}
                onRename={(id) =>
                  onChange(renameConsentID(source, element, id))
                }
              />
            </div>
          </div>
          <DeleteConsentField
            kind={kind}
            id={element.attributes.id}
            onDelete={() => editText(element, "")}
          />
        </div>
      )}
      {element.name === "signature" ?
        <div className="space-y-4" aria-label="Signature preview">
          <div className="grid grid-cols-2 gap-4 text-sm">
            <div className="border-border border-b pb-3">First name</div>
            <div className="border-border border-b pb-3">Last name</div>
          </div>
          <div className="text-text-secondary border-border flex h-24 items-end border-b pb-2">
            Signature
          </div>
        </div>
      : <>
          <div className="flex items-start gap-4">
            <div className="min-w-0 flex-1">
              <MarkdownBlock
                compact
                value={source.slice(label.start, label.end)}
                onChange={(value) => editText(label, `\n${value}\n`)}
                readOnly={readOnly}
              />
            </div>
            {readOnly && element.name === "toggle" && (
              <input
                type="checkbox"
                role="switch"
                aria-label="Example toggle"
                checked={element.attributes["initial-value"] === "true"}
                disabled
                className="mt-2 size-5"
              />
            )}
          </div>
          {element.children.map((child, index) => {
            const content = {
              start: child.contentStart,
              end: child.contentEnd,
            };
            const trailing = {
              start: child.end,
              end: element.children[index + 1]?.start ?? element.contentEnd,
            };
            return (
              <div key={child.start} className="space-y-2">
                <div
                  className={
                    child.name === "footnote" ?
                      "text-text-secondary text-sm"
                    : "border-border border-l-2 pl-3"
                  }
                >
                  {!readOnly && child.name === "option" && (
                    <div className="mb-2">
                      <EditConsentID
                        option
                        id={child.attributes.id ?? ""}
                        onRename={(id) =>
                          onChange(renameConsentID(source, child, id, element))
                        }
                      />
                    </div>
                  )}
                  {!readOnly && child.name === "footnote" && (
                    <p className="text-text-secondary mb-1 text-xs font-medium">
                      Footnote
                    </p>
                  )}
                  <MarkdownBlock
                    compact
                    value={source.slice(content.start, content.end)}
                    onChange={(value) => editText(content, value)}
                    readOnly={readOnly}
                  />
                </div>
                {source.slice(trailing.start, trailing.end).trim() && (
                  <MarkdownBlock
                    compact
                    value={source.slice(trailing.start, trailing.end)}
                    onChange={(value) => editText(trailing, value)}
                    readOnly={readOnly}
                  />
                )}
              </div>
            );
          })}
          {readOnly && element.name === "select" && (
            <select
              aria-label="Example selection"
              className={selectClass}
              value={element.attributes["initial-value"] ?? ""}
              disabled
            >
              <option value="">Choose an option</option>
              {options.map((option) => (
                <option key={option.start} value={option.attributes.id}>
                  {source.slice(option.contentStart, option.contentEnd)}
                </option>
              ))}
            </select>
          )}
          {!readOnly && (
            <div className="border-border grid gap-4 border-t pt-4 sm:grid-cols-2">
              <label className="flex flex-col gap-1 text-sm">
                Initial value
                <select
                  className={selectClass}
                  value={element.attributes["initial-value"] ?? ""}
                  onChange={(event) =>
                    attribute("initial-value", event.target.value)
                  }
                >
                  <option value="">
                    {element.name === "toggle" ?
                      "Off (default)"
                    : "No selection"}
                  </option>
                  {element.name === "toggle" ?
                    <>
                      <option value="true">On</option>
                      <option value="false">Off</option>
                    </>
                  : options.map((option) => (
                      <option key={option.start} value={option.attributes.id}>
                        {option.attributes.id}
                      </option>
                    ))
                  }
                </select>
              </label>
              <label className="flex flex-col gap-1 text-sm">
                Required response
                <select
                  className={selectClass}
                  value={element.attributes["expected-value"] ?? ""}
                  onChange={(event) =>
                    attribute("expected-value", event.target.value)
                  }
                >
                  <option value="">Optional</option>
                  {element.name === "toggle" ?
                    <>
                      <option value="true">Must be on</option>
                      <option value="false">Must be off</option>
                    </>
                  : <>
                      <option value="*">Any option</option>
                      {options.map((option) => (
                        <option key={option.start} value={option.attributes.id}>
                          {option.attributes.id}
                        </option>
                      ))}
                    </>
                  }
                </select>
              </label>
            </div>
          )}
        </>
      }
      {readOnly && element.attributes["expected-value"] && (
        <p className="text-text-secondary text-xs">
          Required response: {requirement}
        </p>
      )}
    </section>
  );
};

export const ConsentEditor = ({ value, onChange, onBlur }: Props) => {
  const [mode, setMode] = useState<Mode>("Preview");
  let blocks: ReturnType<typeof consentBlocks> = [];
  let error: string | undefined;
  try {
    blocks = consentBlocks(value);
  } catch (cause) {
    error =
      cause instanceof Error ?
        cause.message
      : "Review the document in Markdown mode.";
  }
  const readOnly = mode === "Preview";
  return (
    <div className="space-y-5" onBlur={onBlur}>
      <div className="border-border bg-fill-secondary flex flex-wrap items-center justify-between gap-3 rounded-xl border p-3">
        <div
          className="border-border bg-surface flex flex-wrap gap-1 rounded-lg border p-1"
          role="group"
          aria-label="Consent document view"
        >
          {(["Preview", "Visual editor", "Markdown"] as const).map((option) => {
            const Icon = modeIcons[option];
            return (
              <Button
                key={option}
                type="button"
                size="sm"
                variant={mode === option ? "default" : "ghost"}
                aria-pressed={mode === option}
                onClick={() => setMode(option)}
                className="gap-2"
              >
                <Icon className="size-4" />
                {option}
              </Button>
            );
          })}
        </div>
        {!readOnly && (
          <div className="flex flex-wrap gap-2" aria-label="Add consent field">
            {(["toggle", "select", "signature"] as const).map((kind) => (
              <Button
                key={kind}
                type="button"
                variant="outline"
                size="sm"
                onClick={() =>
                  onChange(
                    `${value}${value.endsWith("\n") ? "\n" : "\n\n"}${newConsentField(value, kind)}\n`,
                  )
                }
              >
                <Plus className="mr-1 size-3.5" />
                Add {fieldLabels[kind].toLowerCase()}
              </Button>
            ))}
          </div>
        )}
      </div>
      <p className="text-text-secondary text-sm">
        {readOnly ?
          "Reading preview only. Example responses are not saved; the participant app provides the final presentation."
        : "Edit wording, field IDs and response requirements. Use Markdown for the complete document syntax."
        }{" "}
        Publication still requires server validation.
      </p>
      {error && (
        <p
          role="alert"
          className="text-destructive border-destructive/20 bg-destructive/5 rounded-lg border p-3 text-sm"
        >
          {error}
        </p>
      )}
      {mode === "Markdown" || error ?
        <Textarea
          aria-label="Consent Markdown"
          value={value}
          onChange={(event) => onChange(event.target.value)}
          rows={22}
          className="font-mono text-sm"
        />
      : <div
          className={
            readOnly ?
              "border-border mx-auto max-w-4xl space-y-6 rounded-xl border p-6 sm:p-8"
            : "space-y-6"
          }
          aria-label={
            readOnly ? "Consent reading preview" : "Consent visual editor"
          }
        >
          {blocks.map((block) => {
            if (block.kind === "control")
              return (
                <FieldBlock
                  key={block.element.attributes.id}
                  element={block.element}
                  source={value}
                  onChange={onChange}
                  readOnly={readOnly}
                />
              );
            if (block.kind === "source")
              return (
                <details key={block.start}>
                  <summary className="text-text-secondary text-sm">
                    Document metadata
                  </summary>
                  <Textarea
                    aria-label="Document metadata"
                    value={value.slice(block.start, block.end)}
                    readOnly={readOnly}
                    onChange={(event) =>
                      onChange(replaceRange(value, block, event.target.value))
                    }
                  />
                </details>
              );
            if (!value.slice(block.start, block.end).trim()) return null;
            return (
              <MarkdownBlock
                key={block.start}
                value={value.slice(block.start, block.end)}
                onChange={(content) =>
                  onChange(replaceRange(value, block, `${content}\n\n`))
                }
                readOnly={readOnly}
              />
            );
          })}
          {!blocks.length && (
            <p className="text-text-secondary">
              Add your consent wording in Markdown mode, then edit and preview
              it here.
            </p>
          )}
        </div>
      }
    </div>
  );
};
