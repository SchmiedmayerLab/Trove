// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { describe, expect, it } from "vitest";
import type { FrozenExport } from "@/lib/api/generated/types.gen";
import { verifiedExportFile } from "./studyExportDownload";

const bytes = new TextEncoder().encode('{"resourceType":"Bundle"}\n');
const otherDigest = "0".repeat(64);

const job = async (
  overrides: Partial<FrozenExport> = {},
): Promise<FrozenExport> => {
  const digest = Array.from(
    new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)),
    (value) => value.toString(16).padStart(2, "0"),
  ).join("");
  return {
    id: "11111111-1111-4111-8111-111111111111",
    studyId: "22222222-2222-4222-8222-222222222222",
    versions: "current",
    capturedAt: "2026-11-25T12:00:00.000000Z",
    status: "ready",
    outputCount: 1,
    byteCount: bytes.length,
    recordCount: 1,
    sha256: digest,
    codebook: [],
    exclusions: [],
    ...overrides,
  };
};

describe("verifiedExportFile", () => {
  it("returns the file that matches the manifest", async () => {
    const blob = new Blob([bytes]);
    await expect(verifiedExportFile(blob, await job())).resolves.toBe(blob);
  });

  it("rejects changed bytes, sizes and unprepared exports", async () => {
    const changed = new Blob([
      new TextEncoder().encode('{"resourceType":"Bundlf"}\n'),
    ]);
    await expect(verifiedExportFile(changed, await job())).rejects.toThrow();
    await expect(
      verifiedExportFile(new Blob([bytes.slice(1)]), await job()),
    ).rejects.toThrow();
    await expect(
      verifiedExportFile(new Blob([bytes]), await job({ sha256: otherDigest })),
    ).rejects.toThrow();
    await expect(
      verifiedExportFile(new Blob([bytes]), await job({ status: "queued" })),
    ).rejects.toThrow();
  });
});
