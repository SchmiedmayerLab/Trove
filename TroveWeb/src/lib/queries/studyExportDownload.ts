// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import type { FrozenExport } from "@/lib/api/generated/types.gen";

const hex = (buffer: ArrayBuffer) =>
  Array.from(new Uint8Array(buffer), (value) =>
    value.toString(16).padStart(2, "0"),
  ).join("");

/** Returns the downloaded file only when it is the ready export the manifest describes. */
export const verifiedExportFile = async (
  blob: Blob,
  job: FrozenExport,
): Promise<Blob> => {
  if (job.status !== "ready" || !job.sha256 || blob.size !== job.byteCount)
    throw new Error("The export file does not match its manifest.");
  const digest = hex(
    await crypto.subtle.digest("SHA-256", await blob.arrayBuffer()),
  );
  if (digest !== job.sha256)
    throw new Error("The export file does not match its manifest.");
  return blob;
};
