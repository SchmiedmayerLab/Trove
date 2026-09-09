// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { afterEach, describe, expect, it, vi } from "vitest";
import { ApiError, client } from "./client";

vi.mock("../env", () => ({
  env: { VITE_API_BASE_PATH: "https://api.example.test" },
}));

afterEach(() => vi.unstubAllGlobals());

describe("API error boundary", () => {
  it("preserves a response validator failure rather than inventing an HTTP error", async () => {
    const failure = new Error("Invalid response");
    vi.stubGlobal("fetch", () =>
      Promise.resolve(Response.json({ value: "fixture" })),
    );
    await expect(
      client.get({
        url: "/fixture",
        throwOnError: true,
        responseValidator: () => Promise.reject(failure),
      }),
    ).rejects.toBe(failure);
  });

  it.each([
    new TypeError("Network unavailable"),
    new DOMException("Request cancelled", "AbortError"),
  ])(
    "preserves transport errors without an HTTP response: %s",
    async (error) => {
      vi.stubGlobal("fetch", () => Promise.reject(error));
      await expect(
        client.get({ url: "/fixture", throwOnError: true }),
      ).rejects.toBe(error);
    },
  );

  it.each([401, "401", null, undefined, { value: 401 }])(
    "uses HTTP status rather than the untrusted body status %j",
    async (status) => {
      vi.stubGlobal("fetch", () =>
        Promise.resolve(
          new Response(
            JSON.stringify({
              title: "Unavailable",
              status,
              detail: "Try later",
            }),
            {
              status: 503,
              statusText: "Service Unavailable",
              headers: { "Content-Type": "application/problem+json" },
            },
          ),
        ),
      );
      await expect(
        client.get({ url: "/fixture", throwOnError: true }),
      ).rejects.toMatchObject({
        status: 503,
        message: "Unavailable",
        detail: "Try later",
      });
    },
  );

  it.each(
    [
      null,
      [],
      "untrusted",
      { status: 401, title: {}, detail: [] },
      { status: 401, title: 7, detail: false },
    ].map((body) => ({ body })),
  )(
    "does not cast invalid problem fields into strings: $body",
    async ({ body }) => {
      vi.stubGlobal("fetch", () =>
        Promise.resolve(
          new Response(JSON.stringify(body), {
            status: 401,
            statusText: "Unauthorized",
            headers: { "Content-Type": "application/problem+json" },
          }),
        ),
      );
      const pending = client.get({ url: "/fixture", throwOnError: true });
      await expect(pending).rejects.toBeInstanceOf(ApiError);
      await expect(pending).rejects.toMatchObject({
        status: 401,
        message: "Unauthorized",
        detail: undefined,
      });
    },
  );
});
