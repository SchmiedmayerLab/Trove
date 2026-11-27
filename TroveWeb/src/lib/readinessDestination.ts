// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { isLanguageTag } from "./languageTags";
import { isReadinessFactKey, readinessFactLabels } from "./readinessFacts";

/** Map only paths emitted by the readiness checks to editable controls. */
export const readinessDestination = (path: string) => {
  const fact = /^readinessFacts\.content\.([^.]+)(?:\.([A-Za-z]+))?$/.exec(
    path,
  );
  if (fact && isLanguageTag(fact[1])) {
    const field = fact.at(2);
    if (field === undefined)
      return {
        language: fact[1],
        hash: path,
        label: `Edit translated facts (${fact[1]})`,
      };
    if (!isReadinessFactKey(field)) return undefined;
    return {
      language: fact[1],
      hash: path,
      label: `Edit ${readinessFactLabels[field].toLowerCase()} (${fact[1]})`,
    };
  }
  const contact =
    /^readinessFacts\.contacts(?:\[(\d+)\](?:\.(name|role|email|phone))?)?$/.exec(
      path,
    );
  if (contact)
    return {
      language: undefined,
      hash:
        contact[1] ?
          `readinessFacts.contacts[${contact[1]}].${contact.at(2) ?? "name"}`
        : path,
      label:
        contact[1] ?
          `Edit contact ${Number(contact[1]) + 1} ${contact.at(2) ?? "name"}`
        : "Edit responsible contacts",
    };
};
