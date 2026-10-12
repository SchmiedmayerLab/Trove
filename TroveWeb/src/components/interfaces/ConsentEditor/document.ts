// This source file is part of the Trove open-source project
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

/** Source ranges keep untouched Markdown and field identities byte-for-byte intact.
 * This is an editor projection, not a replacement for Grove/server validation. */
export interface ConsentElement {
  name: string;
  attributes: Partial<Record<string, string>>;
  start: number;
  contentStart: number;
  contentEnd: number;
  end: number;
  children: ConsentElement[];
}

export type ConsentBlock =
  | { kind: "markdown"; start: number; end: number }
  | { kind: "source"; start: number; end: number }
  | { kind: "control"; start: number; end: number; element: ConsentElement };

const openingAt = (source: string, start: number) => {
  const name = /^<([A-Za-z_][\w-]*)/.exec(source.slice(start))?.[1];
  if (!name) throw new Error("Invalid field opening. Review its Markdown.");
  let quoted = false;
  let escaped = false;
  for (
    let cursor = start + name.length + 1;
    cursor < source.length;
    cursor += 1
  ) {
    const character = source[cursor];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (character === "\\" && quoted) {
      escaped = true;
      continue;
    }
    if (character === '"') quoted = !quoted;
    if (character === ">" && !quoted)
      return {
        name,
        end: cursor + 1,
        attributes: source.slice(start + name.length + 1, cursor),
      };
  }
  throw new Error(
    "Incomplete field. Edit its Markdown to finish the opening tag.",
  );
};

const elementAt = (
  source: string,
  start: number,
  depth = 0,
): ConsentElement => {
  if (depth > 2) throw new Error("Nested fields need Markdown review.");
  const opening = openingAt(source, start);
  const name = opening.name;
  let remaining = opening.attributes.replace(/\/$/, "");
  const attributes: Partial<Record<string, string>> = {};
  while (remaining.trim()) {
    const attribute = /^\s+([A-Za-z_][\w-]*)=("(?:\\.|[^"\\])*"|[\w*-]+)/.exec(
      remaining,
    );
    if (!attribute || Object.hasOwn(attributes, attribute[1])) {
      throw new Error(
        "Unsupported or repeated field attribute. Use Markdown mode to review it.",
      );
    }
    attributes[attribute[1]] =
      attribute[2].startsWith('"') ? attribute[2].slice(1, -1) : attribute[2];
    remaining = remaining.slice(attribute[0].length);
  }
  const contentStart = opening.end;
  const children: ConsentElement[] = [];
  if (opening.attributes.endsWith("/")) {
    return {
      name,
      attributes,
      start,
      contentStart,
      contentEnd: contentStart,
      end: contentStart,
      children,
    };
  }
  let cursor = contentStart;
  while (cursor < source.length) {
    const next = source.indexOf("<", cursor);
    if (next < 0) break;
    const close = new RegExp(`^</(?:${name})?>`).exec(source.slice(next));
    if (close)
      return {
        name,
        attributes,
        start,
        contentStart,
        contentEnd: next,
        end: next + close[0].length,
        children,
      };
    const child = elementAt(source, next, depth + 1);
    children.push(child);
    cursor = child.end;
  }
  throw new Error(
    `The ${name} field is not closed. Its source has been preserved.`,
  );
};

const verifyProjection = (element: ConsentElement, ids: Set<string>) => {
  if (!element.attributes.id?.trim() || ids.has(element.attributes.id))
    throw new Error(
      "Every field needs a unique ID. Review the document in Markdown mode.",
    );
  ids.add(element.attributes.id);
  const allowedAttributes =
    element.name === "signature" ?
      ["id"]
    : ["id", "initial-value", "expected-value"];
  if (
    Object.keys(element.attributes).some(
      (name) => !allowedAttributes.includes(name),
    )
  )
    throw new Error(
      "This field has an unsupported attribute. Review it in Markdown mode.",
    );
  const allowedChildren =
    element.name === "select" ? ["footnote", "option"] : ["footnote"];
  if (
    element.children.some(
      (child) =>
        !allowedChildren.includes(child.name) || child.children.length > 0,
    )
  )
    throw new Error(
      "This field structure needs Markdown editing. Its source has been preserved.",
    );
};

export const consentBlocks = (source: string): ConsentBlock[] => {
  const blocks: ConsentBlock[] = [];
  const ids = new Set<string>();
  let cursor = 0;
  let markdownStart = 0;
  let fence: { character: string; length: number } | undefined;
  // Metadata is preserved separately instead of being sent through a rich-text editor.
  if (source.startsWith("---\n") || source.startsWith("---\r\n")) {
    const end = /\r?\n---(?:\r?\n|$)/.exec(source.slice(3));
    if (!end)
      throw new Error(
        "Unclosed document metadata. Review it in Markdown mode.",
      );
    cursor = 3 + end.index + end[0].length;
    blocks.push({ kind: "source", start: 0, end: cursor });
    markdownStart = cursor;
  }
  while (cursor < source.length) {
    const newline = source.indexOf("\n", cursor);
    const lineEnd = newline < 0 ? source.length : newline + 1;
    const line = source.slice(cursor, lineEnd);
    const marker = /^ {0,3}(`{3,}|~{3,})(.*)/.exec(line);
    if (marker) {
      if (!fence) fence = { character: marker[1][0], length: marker[1].length };
      else if (
        marker[1].startsWith(fence.character) &&
        marker[1].length >= fence.length &&
        !marker[2].trim()
      )
        fence = undefined;
    } else if (!fence && /^<(toggle|select|signature)\b/.test(line)) {
      if (cursor > markdownStart)
        blocks.push({ kind: "markdown", start: markdownStart, end: cursor });
      const element = elementAt(source, cursor);
      verifyProjection(element, ids);
      blocks.push({
        kind: "control",
        start: cursor,
        end: element.end,
        element,
      });
      cursor = element.end;
      markdownStart = cursor;
      continue;
    }
    cursor = lineEnd;
  }
  if (markdownStart < source.length)
    blocks.push({ kind: "markdown", start: markdownStart, end: source.length });
  return blocks;
};

export const replaceRange = (
  source: string,
  range: { start: number; end: number },
  replacement: string,
): string =>
  source.slice(0, range.start) + replacement + source.slice(range.end);

export const setFieldAttribute = (
  source: string,
  element: ConsentElement,
  name: "id" | "initial-value" | "expected-value",
  value: string,
): string => {
  const opening = source.slice(element.start, element.contentStart);
  const attribute = new RegExp(
    `\\s+${name}=(?:"(?:\\\\.|[^"\\\\])*"|[\\w*-]+)`,
  );
  const without = opening.replace(attribute, "");
  const updated =
    value === "" ? without : (
      without.replace(/\/?>$/, (ending) => ` ${name}="${value}"${ending}`)
    );
  return replaceRange(
    source,
    { start: element.start, end: element.contentStart },
    updated,
  );
};

/** Rename one identity, updating option references in its enclosing selection. */
export const renameConsentID = (
  source: string,
  element: ConsentElement,
  id: string,
  parent?: ConsentElement,
): string => {
  if (!id.trim() || id !== id.trim())
    throw new Error("Enter an ID without leading or trailing spaces.");
  for (const character of id) {
    if (
      character.charCodeAt(0) < 32 ||
      ['"', "\\", "<", ">"].includes(character)
    ) {
      throw new Error(
        "IDs cannot contain quotes, backslashes, angle brackets or control characters.",
      );
    }
  }
  if (parent && id === "*")
    throw new Error("The ID * is reserved for any-option requirements.");
  const peers =
    parent ?
      parent.children.filter((child) => child.name === "option")
    : consentBlocks(source).flatMap((block) =>
        block.kind === "control" ? [block.element] : [],
      );
  if (
    peers.some(
      (peer) => peer.start !== element.start && peer.attributes.id === id,
    )
  )
    throw new Error(
      parent ?
        "Option IDs must be unique within this selection."
      : "Field IDs must be unique in this document.",
    );
  let updated = setFieldAttribute(source, element, "id", id);
  if (parent) {
    for (const attribute of ["initial-value", "expected-value"] as const) {
      if (parent.attributes[attribute] === element.attributes.id) {
        updated = setFieldAttribute(
          updated,
          elementAt(updated, parent.start),
          attribute,
          id,
        );
      }
    }
  }
  return updated;
};

export const newConsentField = (
  source: string,
  kind: "toggle" | "select" | "signature",
): string => {
  let ordinal = 1;
  while (source.includes(`${kind}-${ordinal}`)) ordinal += 1;
  const id = `${kind}-${ordinal}`;
  switch (kind) {
    case "toggle":
      return `<toggle id="${id}" expected-value="true">\nI agree to participate.\n</toggle>`;
    case "select":
      return `<select id="${id}" expected-value="*">\nPreferred contact method.\n<option id="email">Email</option>\n<option id="phone">Phone</option>\n</select>`;
    case "signature":
      return `<signature id="${id}" />`;
  }
};
