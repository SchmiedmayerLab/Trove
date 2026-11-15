// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { z } from "zod";
import type {
  StudyDataRecord,
  StudyDataVersions,
} from "../api/generated/types.gen";
import { studyBundleBytes } from "./studyData";
import {
  recordingContentTypeSchema,
  recordingFormatSchema,
  recordingFormatSystem,
  recordingMediaMatchesFormat,
} from "./studyRecordingFormats";

const uuid =
  "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}";
const recordingLocation = new RegExp(
  `^/api/v0/studies/(${uuid})/data/recordings/(${uuid})\\?versions=(current|history)$`,
);

export const studyRecordingSchema = z
  .object({
    studyId: z.uuid(),
    grantId: z.uuid(),
    versions: z.enum(["current", "history"]),
    byteCount: z.number().int().min(1).max(2_147_483_647),
    format: recordingFormatSchema,
    contentType: recordingContentTypeSchema,
  })
  .refine(
    (value) => recordingMediaMatchesFormat(value.format, value.contentType),
    "Recording format and media type disagree",
  );

export type StudyRecording = z.infer<typeof studyRecordingSchema>;

const bundleSchema = z.object({
  resourceType: z.literal("Bundle"),
  entry: z
    .array(z.object({ fullUrl: z.string(), resource: z.unknown() }))
    .max(4096),
});
const documentSchema = z.object({
  resourceType: z.literal("DocumentReference"),
  content: z
    .array(
      z.object({
        format: z.object({
          system: z.literal(recordingFormatSystem),
          code: recordingFormatSchema,
        }),
        attachment: z.object({
          url: z.string().optional(),
          data: z.string().optional(),
          contentType: recordingContentTypeSchema,
          size: z.number().int().min(1).max(2_147_483_647),
        }),
      }),
    )
    .length(1),
});

/** Inspect attachment metadata only. Original FHIR bytes are never reserialized. */
export const studyRecordings = (
  record: StudyDataRecord,
  studyId: string,
  versions: StudyDataVersions,
): StudyRecording[] => {
  const document: unknown = JSON.parse(
    new TextDecoder("utf-8", { fatal: true }).decode(
      studyBundleBytes(record.bundleBase64),
    ),
  );
  const bundle = bundleSchema.parse(document);
  const outputs = new Set(record.outputs.map((output) => output.fullUrl));
  const recordings: StudyRecording[] = [];
  for (const entry of bundle.entry) {
    if (!outputs.has(entry.fullUrl)) continue;
    const resource = z
      .object({ resourceType: z.string() })
      .parse(entry.resource);
    if (resource.resourceType !== "DocumentReference") continue;
    const { attachment, format } = documentSchema.parse(entry.resource)
      .content[0];
    if (!recordingMediaMatchesFormat(format.code, attachment.contentType))
      throw new Error("Recording format and media type disagree");
    // Inline recordings remain complete in the downloaded FHIR Bundle.
    if (attachment.url === undefined && attachment.data !== undefined) continue;
    const location = attachment.url?.match(recordingLocation);
    if (
      !location ||
      attachment.data !== undefined ||
      location[1].toLowerCase() !== studyId.toLowerCase() ||
      location[3] !== versions
    ) {
      throw new Error("Invalid study recording location");
    }
    const recording = studyRecordingSchema.parse({
      studyId,
      grantId: location[2],
      versions,
      byteCount: attachment.size,
      format: format.code,
      contentType: attachment.contentType,
    });
    if (
      recordings.some(
        (existing) =>
          existing.grantId.toLowerCase() === recording.grantId.toLowerCase(),
      )
    ) {
      throw new Error("Duplicate study recording");
    }
    recordings.push(recording);
  }
  return recordings;
};
