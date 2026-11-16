// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { afterEach, describe, expect, it, vi } from "vitest";
import { ApiError, setAccessTokenProvider } from "../api/client";
import type { StudyDataPage } from "../api/generated/types.gen";
import {
  loadStudyData,
  studyBundleBytes,
  studyBundleByteLimit,
  studyDataErrorMessage,
} from "./studyData";

vi.mock("../env", () => ({
  env: { VITE_API_BASE_PATH: "https://api.example.test" },
}));

const study = "11111111-1111-4111-8111-111111111111";
const cursor = "22222222-2222-4222-8222-222222222222";
const exactBundle =
  '{"resourceType":"Bundle","value":12345678901234567890.123456789,"text":"é"}';
const page: StudyDataPage = {
  id: "33333333-3333-4333-8333-333333333333",
  studyId: study,
  versions: "current",
  policy: "study-point-view-v1",
  records: [
    {
      id: "44444444-4444-4444-8444-444444444444",
      bundleBase64: Buffer.from(exactBundle).toString("base64"),
      outputs: [
        { fullUrl: "urn:uuid:fixture", isCurrent: true, sourceProfiles: [] },
      ],
    },
  ],
  nextBefore: cursor,
};

afterEach(() => {
  setAccessTokenProvider(undefined);
  vi.unstubAllGlobals();
});

describe("explicit study data retrieval", () => {
  it("requests one uncached page and preserves exact Bundle bytes", async () => {
    const fetch = vi.fn((input: RequestInfo | URL, init?: RequestInit) => {
      const request = new Request(input, init);
      const url = new URL(request.url);
      expect(url.pathname).toBe(`/api/v0/studies/${study}/data`);
      expect(Object.fromEntries(url.searchParams)).toEqual({
        versions: "current",
        limit: "10",
        before: cursor,
      });
      expect(request.cache).toBe("no-store");
      expect(request.headers.get("Authorization")).toBe(
        "Bearer synthetic-token",
      );
      return Promise.resolve(Response.json(page));
    });
    vi.stubGlobal("fetch", fetch);
    setAccessTokenProvider(() => Promise.resolve("synthetic-token"));
    const result = await loadStudyData(
      study,
      "current",
      10,
      cursor,
      new AbortController().signal,
    );
    expect(fetch).toHaveBeenCalledTimes(1);
    expect(result.nextBefore).toBe(cursor);
    expect(studyBundleBytes(result.records[0].bundleBase64)).toEqual(
      new TextEncoder().encode(exactBundle),
    );
  });

  it("keeps a multi-output record whole with a one-record page limit", async () => {
    const record = {
      ...page.records[0],
      outputs: Array.from({ length: 14 }, (_, index) => ({
        ...page.records[0].outputs[0],
        fullUrl: `urn:uuid:workout-${index}`,
      })),
    };
    vi.stubGlobal("fetch", () =>
      Promise.resolve(Response.json({ ...page, records: [record] })),
    );
    const result = await loadStudyData(
      study,
      "current",
      1,
      undefined,
      new AbortController().signal,
    );
    expect(result.records[0].outputs).toHaveLength(14);
  });

  it.each([
    { ...page, studyId: cursor },
    { ...page, versions: "history" },
    { ...page, policy: "unknown" },
    { ...page, records: [page.records[0], page.records[0]] },
  ])(
    "refuses mismatched scope, versions, policy and page size",
    async (response) => {
      vi.stubGlobal("fetch", () => Promise.resolve(Response.json(response)));
      await expect(
        loadStudyData(
          study,
          "current",
          1,
          undefined,
          new AbortController().signal,
        ),
      ).rejects.toThrow();
    },
  );

  it("discards a reply cancelled while its body is being read", async () => {
    const controller = new AbortController();
    const response = Response.json(page);
    response.text = () => {
      controller.abort();
      return Promise.resolve(JSON.stringify(page));
    };
    vi.stubGlobal("fetch", () => Promise.resolve(response));
    await expect(
      loadStudyData(study, "current", 20, undefined, controller.signal),
    ).rejects.toThrow();
  });

  it.each([401, 403, 409, 503])(
    "does not retry or show response details on HTTP %s",
    async (status) => {
      const fetch = vi.fn(() =>
        Promise.resolve(
          Response.json(
            {
              title: "synthetic-sensitive-title",
              detail: "synthetic-sensitive-detail",
            },
            { status },
          ),
        ),
      );
      vi.stubGlobal("fetch", fetch);
      const pending = loadStudyData(
        study,
        "current",
        20,
        undefined,
        new AbortController().signal,
      );
      await expect(pending).rejects.toBeInstanceOf(ApiError);
      await pending.catch((error: unknown) => {
        expect(studyDataErrorMessage(error)).not.toContain(
          "synthetic-sensitive",
        );
      });
      expect(fetch).toHaveBeenCalledTimes(1);
    },
  );

  it("preserves exact bytes above the default 16 MiB Bundle capacity", () => {
    const original = `${exactBundle}${" ".repeat(16 * 1024 * 1024)}`;
    const decoded = studyBundleBytes(Buffer.from(original).toString("base64"));
    expect(decoded).toHaveLength(Buffer.byteLength(original));
    expect(new TextDecoder().decode(decoded)).toBe(original);
  });

  it("refuses malformed or oversized download contents", () => {
    for (const value of [
      "",
      "invalid!",
      "A".repeat(4 * Math.ceil(studyBundleByteLimit / 3) + 1),
    ]) {
      expect(() => studyBundleBytes(value)).toThrow();
    }
  });
});
