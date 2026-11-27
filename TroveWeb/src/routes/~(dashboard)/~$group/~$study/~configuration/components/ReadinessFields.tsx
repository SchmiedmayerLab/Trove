// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { Button, Input, Textarea } from "@schmiedmayerlab/grove-design-system";
import { useFieldArray } from "react-hook-form";
import { readinessFactKeys, readinessFactLabels } from "@/lib/readinessFacts";
import type { GeneralForm } from "../lib/useGeneralForm";

const factHints: Partial<Record<(typeof readinessFactKeys)[number], string>> = {
  concernRoute:
    "How participants reach a person about concerns, and how incidental findings reach a responsible person. A reference to an approved external route suffices.",
  coEnrollment: "The reviewed rule for participants enrolled in other studies.",
};

export const ReadinessFields = ({
  form,
  language,
  source,
}: {
  form: GeneralForm;
  language: string;
  source: boolean;
}) => {
  const contacts = useFieldArray({ control: form.control, name: "contacts" });
  return (
    <section className="grid gap-4 px-6 pt-6">
      <h2 id={`readinessFacts.content.${language}`} tabIndex={-1}>
        Publication readiness
      </h2>
      <p>
        {source ?
          `These facts are required in the source language (${language}) before publication.`
        : `Missing translations in ${language} appear as advisories.`}
      </p>
      {readinessFactKeys.map((fact) => {
        const id = `readinessFacts.content.${language}.${fact}`;
        const hint = factHints[fact];
        return (
          <div key={fact} className="grid gap-1">
            <label htmlFor={id}>{readinessFactLabels[fact]}</label>
            {hint && (
              <p id={`${id}.hint`} className="text-muted-foreground text-sm">
                {hint}
              </p>
            )}
            <Textarea
              id={id}
              lang={language}
              dir="auto"
              maxLength={10000}
              aria-describedby={hint ? `${id}.hint` : undefined}
              {...form.register(`facts.${fact}`)}
            />
          </div>
        );
      })}
      <h3>Responsible contacts</h3>
      <p>
        Each contact needs a name, a role and an email address or phone number.
        Contacts apply to every language.
      </p>
      {contacts.fields.map((row, i) => (
        <fieldset key={row.id} className="grid gap-2">
          <legend>Contact {i + 1}</legend>
          {(["name", "role", "email", "phone"] as const).map((key) => (
            <label className="grid gap-1" key={key}>
              {key[0].toUpperCase() + key.slice(1)}
              <Input
                id={`readinessFacts.contacts[${i}].${key}`}
                maxLength={{ name: 200, role: 200, email: 320, phone: 64 }[key]}
                {...form.register(`contacts.${i}.${key}`)}
              />
            </label>
          ))}
          <Button
            type="button"
            variant="outline"
            onClick={() => {
              contacts.remove(i);
              requestAnimationFrame(() =>
                document.getElementById("readinessFacts.contacts")?.focus(),
              );
            }}
          >
            Remove contact {i + 1}
          </Button>
        </fieldset>
      ))}
      <Button
        id="readinessFacts.contacts"
        type="button"
        variant="outline"
        disabled={contacts.fields.length >= 16}
        onClick={() =>
          contacts.append(
            { name: "", role: "" },
            { focusName: `contacts.${contacts.fields.length}.name` },
          )
        }
      >
        Add contact
      </Button>
    </section>
  );
};
