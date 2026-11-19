// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import type {
  ValidationDiagnostic,
  ValidationStatus,
} from "./api/generated/types.gen";

export const statusSummary: Record<ValidationStatus, string> = {
  valid: "Valid. Every check ran and passed.",
  invalid: "Invalid. Resolve the errors before publishing.",
  incomplete:
    "Not fully checked. At least one check could not be evaluated, so validity is not established.",
  unavailable:
    "Not checked. The validator could not be reached; validate again later.",
};

export const severityLabel: Record<ValidationDiagnostic["severity"], string> = {
  error: "Error",
  warning: "Warning",
  information: "Information",
};

export const sourceLabel: Record<ValidationDiagnostic["source"], string> = {
  fhir: "FHIR Validator",
  grove: "Grove rules",
  trove: "Trove rules",
};

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

/**
 * The linkId of the innermost item a Questionnaire FHIRPath such as `Questionnaire.item[1].item[0].text`
 * names, read from the JSON text; `undefined` when the path names no item or the text is not JSON.
 */
export const itemLinkId = (text: string, path: string): string | undefined => {
  const steps = path.split(".");
  if (steps[0] !== "Questionnaire") return undefined;
  let resource: unknown;
  try {
    resource = JSON.parse(text);
  } catch {
    return undefined;
  }
  let node = resource;
  let linkId: string | undefined;
  for (const step of steps.slice(1)) {
    const match = /^item\[(\d+)\]$/.exec(step);
    if (!match || !isRecord(node) || !Array.isArray(node.item)) break;
    node = node.item[Number(match[1])];
    if (!isRecord(node) || typeof node.linkId !== "string") return linkId;
    linkId = node.linkId;
  }
  return linkId;
};

const parseString = (literal: string): unknown => {
  try {
    return JSON.parse(literal);
  } catch {
    return undefined;
  }
};

/**
 * The character range of an item's `"linkId": "<id>"` member in the JSON text. Strings are read in order,
 * so text inside a string value that looks like a member is never matched.
 */
export const linkIdRange = (
  text: string,
  linkId: string,
): [number, number] | undefined => {
  const strings = /"(?:[^"\\]|\\.)*"/g;
  let previous: RegExpExecArray | null = null;
  for (let match = strings.exec(text); match; match = strings.exec(text)) {
    if (
      previous?.[0] === '"linkId"' &&
      /^\s*:\s*$/.test(
        text.slice(previous.index + previous[0].length, match.index),
      ) &&
      parseString(match[0]) === linkId
    ) {
      return [previous.index, match.index + match[0].length];
    }
    previous = match;
  }
  return undefined;
};
