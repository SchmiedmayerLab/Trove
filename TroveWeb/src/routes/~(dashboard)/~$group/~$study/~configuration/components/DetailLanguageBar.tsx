//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import {
  Button,
  Input,
  Label,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@schmiedmayerlab/grove-design-system";
import { useId, useState } from "react";
import { isLanguageTag } from "../lib/studyDetails";

interface DetailLanguageBarProps {
  languages: string[];
  sourceLanguage: string;
  language: string;
  /** Whether `language` has saved details; only saved translations can become the source or be removed. */
  isSaved: boolean;
  /** Unsaved edits keep the current language. */
  disabled: boolean;
  onSelect: (language: string) => void;
  onMakeSource: () => void;
  onRemove: () => void;
}

export const DetailLanguageBar = ({
  languages,
  sourceLanguage,
  language,
  isSaved,
  disabled,
  onSelect,
  onMakeSource,
  onRemove,
}: DetailLanguageBarProps) => {
  const selectId = useId();
  const inputId = useId();
  const [newLanguage, setNewLanguage] = useState("");
  const isValid = isLanguageTag(newLanguage);

  const add = () => {
    if (!isValid) return;
    onSelect(newLanguage);
    setNewLanguage("");
  };

  return (
    <div className="border-border-tertiary flex flex-wrap items-end gap-3 border-b px-6 pb-6">
      <div className="flex flex-col gap-2">
        <Label htmlFor={selectId}>Language</Label>
        <Select
          id={selectId}
          value={language}
          onValueChange={onSelect}
          disabled={disabled}
        >
          <SelectTrigger className="w-48">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {languages.map((tag) => (
              <SelectItem key={tag} value={tag}>
                {tag === sourceLanguage ? `${tag} (source)` : tag}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>
      <form
        onSubmit={(event) => {
          event.preventDefault();
          add();
        }}
        className="flex flex-col gap-2"
      >
        <Label htmlFor={inputId}>Add a language</Label>
        <div className="flex gap-2">
          <Input
            id={inputId}
            value={newLanguage}
            onChange={(event) => setNewLanguage(event.target.value.trim())}
            placeholder="e.g. de, zh-Hant, pt-BR"
            aria-invalid={newLanguage !== "" && !isValid}
            disabled={disabled}
            className="w-48"
          />
          <Button
            type="submit"
            size="sm"
            variant="outlineBg"
            disabled={disabled || !isValid}
          >
            Add
          </Button>
        </div>
      </form>
      {language !== sourceLanguage && isSaved && (
        <div className="flex gap-2">
          <Button
            type="button"
            size="sm"
            variant="outlineBg"
            disabled={disabled}
            onClick={onMakeSource}
          >
            Make source language
          </Button>
          <Button
            type="button"
            size="sm"
            variant="outlineBg"
            disabled={disabled}
            onClick={onRemove}
          >
            Remove language
          </Button>
        </div>
      )}
    </div>
  );
};
