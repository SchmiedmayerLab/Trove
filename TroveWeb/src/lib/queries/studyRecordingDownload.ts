// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { ApiError, apiSessionSignal } from "../api/client";
import { getStudyRecording } from "../api/generated/sdk.gen";
import {
  recordingFileExtension,
  recordingOriginalMediaHeaderMatches,
  type RecordingContentType,
} from "./studyRecordingFormats";
import { studyRecordingSchema, type StudyRecording } from "./studyRecordings";

/** Browser fallback payload budget; native file writes stream independently of this limit. */
export const recordingFallbackByteLimit = 64 * 1024 * 1024;
export const recordingFallbackCapacityMessage = `This browser can save recordings up to ${recordingFallbackByteLimit / 1024 / 1024} MiB. For larger recordings, use the Trove CLI or a browser with streaming file saves.`;

type SavePicker = (options: {
  suggestedName: string;
  types: Array<{ description: string; accept: Record<string, string[]> }>;
}) => Promise<FileSystemFileHandle>;

const savePicker = (): SavePicker | undefined =>
  typeof window === "undefined" ? undefined : (
    (window as Window & { showSaveFilePicker?: SavePicker }).showSaveFilePicker
  );

export const supportsStreamingRecordingSave = (): boolean =>
  typeof savePicker() === "function";

class RecordingCapacityError extends Error {}

const startBlobDownload = (
  chunks: Array<Uint8Array<ArrayBuffer>>,
  name: string,
  contentType: RecordingContentType,
) => {
  const url = URL.createObjectURL(new Blob(chunks, { type: contentType }));
  try {
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = name;
    anchor.click();
  } finally {
    setTimeout(() => URL.revokeObjectURL(url), 0);
  }
};

/** One explicit disclosure, with backpressure and no partial destination commit on failure. */
export const downloadStudyRecording = async (
  requested: StudyRecording,
  cancellation: AbortSignal,
  progress: (receivedBytes: number) => void,
): Promise<"saved" | "started"> => {
  const recording = studyRecordingSchema.parse(requested);
  const signal = AbortSignal.any([cancellation, apiSessionSignal()]);
  signal.throwIfAborted();
  const picker = savePicker();
  if (!picker && recording.byteCount > recordingFallbackByteLimit) {
    throw new RecordingCapacityError();
  }
  const suffix = recordingFileExtension(recording.contentType);
  const name = `recording-${recording.grantId.toLowerCase()}${suffix}`;
  // The picker must be invoked synchronously from the user's click, before token refresh.
  const handle =
    picker ?
      await picker.call(window, {
        suggestedName: name,
        types: [
          {
            description: "Original source recording",
            accept: { [recording.contentType.split(";")[0]]: [suffix] },
          },
        ],
      })
    : undefined;
  signal.throwIfAborted();
  const { response, request } = await getStudyRecording({
    path: { studyId: recording.studyId, grantId: recording.grantId },
    query: { versions: recording.versions },
    signal,
    cache: "no-store",
    parseAs: "stream",
    throwOnError: true,
  });
  const active = AbortSignal.any([signal, request.signal]);
  let destination: WritableStream<Uint8Array<ArrayBuffer>> | undefined;
  let complete = false;
  try {
    active.throwIfAborted();
    if (
      response.headers.get("Content-Type")?.trim().toLowerCase() !==
        "application/octet-stream" ||
      !recordingOriginalMediaHeaderMatches(
        response.headers.get("X-Recording-Content-Type"),
        recording.contentType,
      ) ||
      response.headers.get("Cache-Control")?.toLowerCase() !== "no-store" ||
      !response.body
    ) {
      throw new Error("Invalid recording response");
    }
    const chunks: Array<Uint8Array<ArrayBuffer>> = [];
    destination =
      handle ?
        await handle.createWritable()
      : new WritableStream({
          write(chunk: Uint8Array<ArrayBuffer>) {
            chunks.push(Uint8Array.from(chunk));
          },
        });
    active.throwIfAborted();
    let received = 0;
    const bounded = new TransformStream<
      Uint8Array<ArrayBuffer>,
      Uint8Array<ArrayBuffer>
    >({
      transform(chunk, controller) {
        active.throwIfAborted();
        if (chunk.byteLength > recording.byteCount - received)
          throw new Error("Recording size mismatch");
        received += chunk.byteLength;
        controller.enqueue(chunk);
        progress(received);
      },
      flush() {
        active.throwIfAborted();
        if (received !== recording.byteCount)
          throw new Error("Recording size mismatch");
      },
    });
    await response.body
      .pipeThrough(bounded)
      .pipeTo(destination, { signal: active });
    active.throwIfAborted();
    if (!handle) startBlobDownload(chunks, name, recording.contentType);
    complete = true;
    return handle ? "saved" : "started";
  } finally {
    if (!complete) {
      await response.body?.cancel().catch(() => undefined);
      await destination?.abort().catch(() => undefined);
    }
  }
};

export const recordingDownloadErrorMessage = (error: unknown): string => {
  if (error instanceof DOMException && error.name === "AbortError")
    return "Recording download cancelled.";
  if (error instanceof RecordingCapacityError)
    return recordingFallbackCapacityMessage;
  if (error instanceof ApiError) {
    switch (error.status) {
      case 401:
        return "Your session is no longer authorized. Sign in again.";
      case 403:
        return "You do not have permission to download this study's recordings.";
      case 404:
      case 409:
        return "This recording is no longer available in this view. Load the study data again.";
      case 503:
        return "This recording is temporarily unavailable or exceeds the server's download capacity. Try again later.";
    }
  }
  return "Unable to save this recording. Check available disk space and try again.";
};
