// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { afterEach, describe, expect, it, vi } from "vitest";
import { client, setAccessTokenProvider } from "./client";

vi.mock("../env", () => ({
  env: { VITE_API_BASE_PATH: "https://api.example.test" },
}));

const deferred = <T>() => {
  let resolve: (value: T | PromiseLike<T>) => void = () => {
    throw new Error("Promise resolver is not initialized");
  };
  const promise = new Promise<T>((accept) => {
    resolve = accept;
  });
  return { promise, resolve };
};
const result = () =>
  new Response(JSON.stringify({ value: "current" }), {
    headers: { "Content-Type": "application/json" },
  });

afterEach(() => {
  setAccessTokenProvider(undefined);
  vi.unstubAllGlobals();
});

describe("API session isolation", () => {
  it("never sends its bearer token to a different origin", async () => {
    const provider = vi.fn(() => Promise.resolve("current-token"));
    const fetch = vi.fn(() => Promise.resolve(result()));
    vi.stubGlobal("fetch", fetch);
    setAccessTokenProvider(provider);
    await expect(
      client.get({
        baseUrl: "https://other.example.test",
        url: "/fixture",
        throwOnError: true,
      }),
    ).rejects.toThrow("API requests must use the configured origin");
    expect(provider).not.toHaveBeenCalled();
    expect(fetch).not.toHaveBeenCalled();
  });

  it("rejects redirects and replaces caller-supplied credentials", async () => {
    let sent: Request | undefined;
    vi.stubGlobal("fetch", (input: RequestInfo | URL, init?: RequestInit) => {
      sent = new Request(input, init);
      return Promise.resolve(result());
    });
    setAccessTokenProvider(() => Promise.resolve("current-token"));
    await client.get({
      url: "/fixture",
      headers: { Authorization: "Bearer stale-token" },
      throwOnError: true,
    });
    expect(sent?.redirect).toBe("error");
    expect(sent?.headers.get("Authorization")).toBe("Bearer current-token");
  });

  it("does not expose an unstructured token-provider rejection", async () => {
    vi.stubGlobal("fetch", vi.fn());
    setAccessTokenProvider(
      vi
        .fn<() => Promise<string | undefined>>()
        .mockRejectedValue({ token: "synthetic-secret" }),
    );
    await expect(
      client.get({ url: "/fixture", throwOnError: true }),
    ).rejects.toThrow("Token refresh failed");
    expect(fetch).not.toHaveBeenCalled();
  });

  it("does not wait for a stalled refresh after logout", async () => {
    const refresh = deferred<string | undefined>();
    const started = deferred<undefined>();
    vi.stubGlobal("fetch", () => Promise.resolve(result()));
    setAccessTokenProvider(() => {
      started.resolve(undefined);
      return refresh.promise;
    });
    let finished = false;
    const outcome = client.get({ url: "/fixture", throwOnError: true }).then(
      () => "resolved",
      (error: unknown) =>
        error instanceof DOMException ? error.name : "unexpected error",
    );
    void outcome.then(() => {
      finished = true;
    });
    await started.promise;
    setAccessTokenProvider(undefined);
    try {
      await vi.waitFor(() => expect(finished).toBe(true));
    } finally {
      refresh.resolve("old-token");
    }
    expect(await outcome).toBe("AbortError");
  });

  it("shares only the current refresh and releases it afterward", async () => {
    const refresh = deferred<string | undefined>();
    const started = deferred<undefined>();
    const provider = vi.fn(() => {
      started.resolve(undefined);
      return refresh.promise;
    });
    const sent: Array<string | null> = [];
    vi.stubGlobal("fetch", (input: RequestInfo | URL, init?: RequestInit) => {
      sent.push(new Request(input, init).headers.get("Authorization"));
      return Promise.resolve(result());
    });
    setAccessTokenProvider(provider);
    const first = client.get({ url: "/fixture", throwOnError: true });
    const second = client.get({ url: "/fixture", throwOnError: true });
    await started.promise;
    refresh.resolve("current-token");
    await Promise.all([first, second]);
    expect(provider).toHaveBeenCalledTimes(1);
    await client.get({ url: "/fixture", throwOnError: true });
    expect(provider).toHaveBeenCalledTimes(2);
    expect(sent).toEqual(Array<string>(3).fill("Bearer current-token"));
  });

  it("allows a fresh attempt after refresh failure", async () => {
    const failure = new Error("Refresh unavailable");
    const provider = vi
      .fn<() => Promise<string | undefined>>()
      .mockRejectedValueOnce(failure)
      .mockResolvedValueOnce("current-token");
    const fetch = vi.fn(() => Promise.resolve(result()));
    vi.stubGlobal("fetch", fetch);
    setAccessTokenProvider(provider);
    await expect(
      client.get({ url: "/fixture", throwOnError: true }),
    ).rejects.toBe(failure);
    expect(fetch).not.toHaveBeenCalled();
    await client.get({ url: "/fixture", throwOnError: true });
    expect(provider).toHaveBeenCalledTimes(2);
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it("does not send anonymously when a registered provider has no token", async () => {
    const fetch = vi.fn(() => Promise.resolve(result()));
    vi.stubGlobal("fetch", fetch);
    setAccessTokenProvider(() => Promise.resolve(undefined));
    await expect(
      client.get({ url: "/fixture", throwOnError: true }),
    ).rejects.toMatchObject({ status: 401 });
    expect(fetch).not.toHaveBeenCalled();
  });

  it("preserves per-request cancellation without cancelling other requests", async () => {
    const refresh = deferred<string | undefined>();
    const started = deferred<undefined>();
    const fetch = vi.fn(() => Promise.resolve(result()));
    vi.stubGlobal("fetch", fetch);
    setAccessTokenProvider(() => {
      started.resolve(undefined);
      return refresh.promise;
    });
    const controller = new AbortController();
    const cancelled = client.get({
      url: "/fixture",
      signal: controller.signal,
      throwOnError: true,
    });
    const rejected = expect(cancelled).rejects.toMatchObject({
      name: "AbortError",
    });
    const current = client.get({ url: "/fixture", throwOnError: true });
    await started.promise;
    controller.abort();
    refresh.resolve("current-token");
    await rejected;
    await current;
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it("does not send a request after logout during token refresh", async () => {
    const refresh = deferred<string | undefined>();
    const started = deferred<undefined>();
    const fetch = vi.fn(() => Promise.resolve(result()));
    vi.stubGlobal("fetch", fetch);
    setAccessTokenProvider(() => {
      started.resolve(undefined);
      return refresh.promise;
    });
    const pending = client.get({ url: "/fixture", throwOnError: true });
    const rejected = expect(pending).rejects.toMatchObject({
      name: "AbortError",
    });
    await started.promise;
    setAccessTokenProvider(undefined);
    refresh.resolve("old-token");
    await rejected;
    expect(fetch).not.toHaveBeenCalled();
  });

  it("does not adopt a replacement session before dispatch", async () => {
    const fetch = vi.fn(() => Promise.resolve(result()));
    vi.stubGlobal("fetch", fetch);
    setAccessTokenProvider(() => Promise.resolve("old-token"));
    const pending = client.post({ url: "/fixture", throwOnError: true });
    const rejected = expect(pending).rejects.toMatchObject({
      name: "AbortError",
    });
    setAccessTokenProvider(() => Promise.resolve("new-token"));
    await rejected;
    expect(fetch).not.toHaveBeenCalled();
  });

  it("does not share a pending refresh with a replacement session", async () => {
    const oldRefresh = deferred<string | undefined>();
    const started = deferred<undefined>();
    const sent: Array<string | null> = [];
    vi.stubGlobal("fetch", (input: RequestInfo | URL, init?: RequestInit) => {
      sent.push(new Request(input, init).headers.get("Authorization"));
      return Promise.resolve(result());
    });
    setAccessTokenProvider(() => {
      started.resolve(undefined);
      return oldRefresh.promise;
    });
    const oldRequest = client.get({ url: "/fixture", throwOnError: true });
    const rejected = expect(oldRequest).rejects.toMatchObject({
      name: "AbortError",
    });
    await started.promise;
    const newProvider = vi.fn(() => Promise.resolve("new-token"));
    setAccessTokenProvider(newProvider);
    const current = client.get({ url: "/fixture", throwOnError: true });
    oldRefresh.resolve("old-token");
    await rejected;
    await current;
    expect(newProvider).toHaveBeenCalledTimes(1);
    expect(sent).toEqual(["Bearer new-token"]);
  });

  it("rejects a late response even when the transport ignores cancellation", async () => {
    const response = deferred<Response>();
    const sent = deferred<Request>();
    vi.stubGlobal("fetch", (input: RequestInfo | URL, init?: RequestInit) => {
      sent.resolve(new Request(input, init));
      return response.promise;
    });
    setAccessTokenProvider(() => Promise.resolve("old-token"));
    const pending = client.get({ url: "/fixture", throwOnError: true });
    const rejected = expect(pending).rejects.toMatchObject({
      name: "AbortError",
    });
    const request = await sent.promise;
    setAccessTokenProvider(undefined);
    const aborted = request.signal.aborted;
    response.resolve(result());
    await rejected;
    expect(aborted).toBe(true);
  });

  it("rejects JSON that finishes decoding after logout", async () => {
    const decoding = deferred<undefined>();
    const body = deferred<unknown>();
    const response = result();
    vi.spyOn(response, "text").mockImplementation(() => {
      decoding.resolve(undefined);
      return body.promise.then((value) => JSON.stringify(value));
    });
    vi.stubGlobal("fetch", () => Promise.resolve(response));
    setAccessTokenProvider(() => Promise.resolve("old-token"));
    const pending = client.get({ url: "/fixture", throwOnError: true });
    const rejected = expect(pending).rejects.toMatchObject({
      name: "AbortError",
    });
    await decoding.promise;
    setAccessTokenProvider(undefined);
    body.resolve({ secret: "old-session" });
    await rejected;
  });

  it("rejects a late HTTP error body from a prior session", async () => {
    const decoding = deferred<undefined>();
    const body = deferred<string>();
    const response = new Response(null, { status: 403 });
    vi.spyOn(response, "text").mockImplementation(() => {
      decoding.resolve(undefined);
      return body.promise;
    });
    vi.stubGlobal("fetch", () => Promise.resolve(response));
    setAccessTokenProvider(() => Promise.resolve("old-token"));
    const pending = client.get({ url: "/fixture", throwOnError: true });
    const rejected = expect(pending).rejects.toMatchObject({
      name: "AbortError",
    });
    await decoding.promise;
    setAccessTokenProvider(undefined);
    body.resolve(JSON.stringify({ title: "Old session detail" }));
    await rejected;
  });

  it("preserves response validation and rejects a late transformation", async () => {
    const transforming = deferred<undefined>();
    const transformed = deferred<unknown>();
    const validator = vi.fn((data: unknown) => Promise.resolve(data));
    vi.stubGlobal("fetch", () => Promise.resolve(result()));
    setAccessTokenProvider(() => Promise.resolve("old-token"));
    const pending = client.get({
      url: "/fixture",
      throwOnError: true,
      responseValidator: validator,
      responseTransformer: () => {
        transforming.resolve(undefined);
        return transformed.promise;
      },
    });
    const rejected = expect(pending).rejects.toMatchObject({
      name: "AbortError",
    });
    await transforming.promise;
    setAccessTokenProvider(undefined);
    transformed.resolve({ secret: "old-session" });
    await rejected;
    expect(validator).toHaveBeenCalledWith({ value: "current" });
  });

  it("rejects an HTTP error decoded after per-request cancellation", async () => {
    const decoding = deferred<undefined>();
    const body = deferred<string>();
    const response = new Response(null, { status: 403 });
    vi.spyOn(response, "text").mockImplementation(() => {
      decoding.resolve(undefined);
      return body.promise;
    });
    vi.stubGlobal("fetch", () => Promise.resolve(response));
    const controller = new AbortController();
    const pending = client.get({
      url: "/fixture",
      signal: controller.signal,
      throwOnError: true,
    });
    const rejected = expect(pending).rejects.toMatchObject({
      name: "AbortError",
    });
    await decoding.promise;
    controller.abort();
    body.resolve(JSON.stringify({ title: "Cancelled response" }));
    await rejected;
  });
});
