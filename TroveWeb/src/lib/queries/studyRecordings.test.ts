// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { describe, expect, it, vi } from "vitest";
import type { StudyDataRecord } from "../api/generated/types.gen";
import { studyBundleBytes } from "./studyData";
import { studyRecordings } from "./studyRecordings";

vi.mock("../env", () => ({
  env: { VITE_API_BASE_PATH: "https://api.example.test" },
}));

const study = "11111111-1111-4111-8111-111111111111";
const grant = "22222222-2222-4222-8222-222222222222";
const location = `/api/v0/studies/${study}/data/recordings/${grant}?versions=current`;
const fullUrl = `urn:uuid:${grant}`;
const record = (
  attachment: Record<string, unknown>,
  includeOutput = true,
): StudyDataRecord => ({
  id: grant,
  bundleBase64: Buffer.from(
    `{"resourceType":"Bundle","entry":[{"fullUrl":"${fullUrl}","resource":{"resourceType":"DocumentReference","content":[{"attachment":${JSON.stringify({ contentType: "text/csv", size: 42, ...attachment })}}]}},{"fullUrl":"urn:uuid:observation","resource":{"resourceType":"Observation","valueQuantity":{"value":12345678901234567890.123456789}}}]}`,
  ).toString("base64"),
  outputs:
    includeOutput ? [{ fullUrl, isCurrent: true, sourceProfiles: [] }] : [],
});

describe("study recording attachment selection", () => {
  it("reads only recording metadata and preserves original FHIR numeric bytes", () => {
    const input = record({ url: location });
    const original = studyBundleBytes(input.bundleBase64);
    expect(studyRecordings(input, study, "current")).toEqual([
      { studyId: study, grantId: grant, versions: "current", byteCount: 42 },
    ]);
    expect(studyBundleBytes(input.bundleBase64)).toEqual(original);
    expect(new TextDecoder().decode(original)).toContain(
      "12345678901234567890.123456789",
    );
  });

  it("accepts the explicitly requested historical view", () => {
    expect(
      studyRecordings(
        record({ url: location.replace("current", "history") }),
        study,
        "history",
      )[0].versions,
    ).toBe("history");
  });

  it.each([
    `https://other.example${location}`,
    `https://api.example.test${location}`,
    location.replace(study, grant),
    location.replace("current", "history"),
    `${location}&extra=true`,
    `${location}#fragment`,
    location.replace("/recordings/", "/recordings%2F"),
  ])(
    "refuses an attachment outside the exact authorized endpoint: %s",
    (url) => {
      expect(() =>
        studyRecordings(record({ url }), study, "current"),
      ).toThrow();
    },
  );

  it.each([
    { url: location, size: 0 },
    { url: location, size: 2_147_483_648 },
    { url: location, size: 1.5 },
    { url: location, data: "YQ==" },
    { url: location, contentType: "application/octet-stream" },
    {},
  ])("refuses ambiguous or invalid recording metadata", (attachment) => {
    expect(() =>
      studyRecordings(record(attachment), study, "current"),
    ).toThrow();
  });

  it("leaves inline recordings in FHIR and does not offer ungranted attachments", () => {
    expect(studyRecordings(record({ data: "YQ==" }), study, "current")).toEqual(
      [],
    );
    expect(
      studyRecordings(
        record({ url: "https://other.example" }, false),
        study,
        "current",
      ),
    ).toEqual([]);
  });
});
