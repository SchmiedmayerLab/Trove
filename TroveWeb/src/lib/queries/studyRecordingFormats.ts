// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { z } from "zod";

export const recordingFormatSystem =
  "https://grovealliance.org/fhir/sensor/CodeSystem/grove-recording-format";

/** Download representations from Grove's closed recording-format registry; this does not admit collection. */
export const recordingMediaTypes = {
  "ambient-light-samples": ["text/csv"],
  "ambient-pressure-samples": ["text/csv"],
  "beat-interval-series": ["text/csv"],
  "clinical-document": ["application/hl7-cda+xml"],
  "device-motion-samples": ["text/csv"],
  "fhir-collection-bundle": ["application/fhir+json"],
  "fhir-resource": [
    "application/fhir+json; fhirVersion=1.0",
    "application/fhir+json; fhirVersion=4.0",
  ],
  "headphone-settings-samples": ["text/csv"],
  "heart-rate-samples": ["text/csv"],
  "location-track-samples": ["text/csv"],
  "native-recording": ["application/json"],
  "odometer-samples": ["text/csv"],
  "pedometer-samples": ["text/csv"],
  "photoplethysmogram-samples": ["application/octet-stream"],
  "provider-recording": ["application/json"],
  "triaxial-acceleration-samples": ["text/csv"],
  "triaxial-rotation-samples": ["text/csv"],
  "wrist-temperature-samples": ["text/csv"],
} as const;

export const recordingFormatSchema = z.enum(
  Object.keys(recordingMediaTypes) as [
    keyof typeof recordingMediaTypes,
    ...Array<keyof typeof recordingMediaTypes>,
  ],
);
export const recordingContentTypeSchema = z.enum([
  "text/csv",
  "application/json",
  "application/octet-stream",
  "application/fhir+json",
  "application/fhir+json; fhirVersion=1.0",
  "application/fhir+json; fhirVersion=4.0",
  "application/hl7-cda+xml",
]);
export type RecordingContentType = z.infer<typeof recordingContentTypeSchema>;

export const recordingMediaMatchesFormat = (
  format: keyof typeof recordingMediaTypes,
  contentType: string,
): boolean =>
  (recordingMediaTypes[format] as readonly string[]).includes(contentType);

/** Stable safe suffixes; neither the provider's document title nor a response filename becomes a local path. */
export const recordingFileExtension = (
  contentType: RecordingContentType,
): string => {
  switch (contentType) {
    case "text/csv":
      return ".csv";
    case "application/hl7-cda+xml":
      return ".xml";
    case "application/octet-stream":
      return ".bin";
    default:
      return ".json";
  }
};

/** Version parameters are significant. Only an optional UTF-8 charset may supplement the declared representation. */
export const recordingResponseMediaMatches = (
  actual: string | null,
  expected: RecordingContentType,
): boolean => {
  if (!actual || actual.length > 256) return false;
  const normalize = (value: string): string | undefined => {
    const [base, ...parameters] = value.split(";").map((part) => part.trim());
    const found = new Map<string, string>();
    for (const parameter of parameters) {
      const match = /^([a-zA-Z]+)=("?)([^"\s;]+)\2$/.exec(parameter);
      if (!match) return undefined;
      const key = match[1].toLowerCase();
      if (found.has(key) || !["charset", "fhirversion"].includes(key))
        return undefined;
      found.set(key, match[3]);
    }
    const charset = found.get("charset");
    if (charset !== undefined && charset.toLowerCase() !== "utf-8")
      return undefined;
    const version = found.get("fhirversion");
    return (
      base.toLowerCase() +
      (version === undefined ? "" : `;fhirversion=${version}`)
    );
  };
  const normalized = normalize(actual);
  return normalized !== undefined && normalized === normalize(expected);
};

/** The OpenAPI simple header representation is URI-component encoded; decode exactly once before validating media. */
export const recordingOriginalMediaHeaderMatches = (
  header: string | null,
  expected: RecordingContentType,
): boolean => {
  if (!header || header.length > 768) return false;
  try {
    const decoded = decodeURIComponent(header);
    if (!/^[\x20-\x7e]+$/.test(decoded)) return false;
    return recordingResponseMediaMatches(decoded, expected);
  } catch {
    return false;
  }
};
