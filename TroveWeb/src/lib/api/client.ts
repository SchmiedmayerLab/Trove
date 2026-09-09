//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { env } from "../env";
import { client } from "./generated/client.gen";

/**
 * Structured API error based on RFC 7807 Problem Details.
 * Preserves the HTTP status code so callers can distinguish
 * 401s, 403s, 404s, etc. without string-matching on the message.
 */
export class ApiError extends Error {
  readonly status: number;
  readonly detail?: string;

  constructor({
    title,
    status,
    detail,
  }: {
    title: string;
    status: number;
    detail?: string;
  }) {
    super(title);
    this.name = "ApiError";
    this.status = status;
    this.detail = detail;
  }
}

type AccessTokenProvider = () => Promise<string | undefined>;
const apiOrigin = new URL(env.VITE_API_BASE_PATH).origin;

const createSession = (provider: AccessTokenProvider | undefined) => {
  const controller = new AbortController();
  let refresh: Promise<string | undefined> | undefined;
  const check = () => controller.signal.throwIfAborted();
  const fetch: typeof globalThis.fetch = async (input, init) => {
    check();
    const original = new Request(input, init);
    if (new URL(original.url).origin !== apiOrigin) {
      throw new Error("API requests must use the configured origin");
    }
    const request = new Request(original, {
      redirect: "error",
      signal: AbortSignal.any([original.signal, controller.signal]),
    });
    request.signal.throwIfAborted();
    request.headers.delete("Authorization");
    if (provider) {
      refresh ??= Promise.resolve()
        .then(() => {
          check();
          return provider();
        })
        .finally(() => {
          refresh = undefined;
        });
      const pending = refresh;
      const token = await new Promise<string | undefined>((resolve, reject) => {
        const cancelled = () =>
          reject(new DOMException("The request was cancelled.", "AbortError"));
        request.signal.addEventListener("abort", cancelled, { once: true });
        void pending.then(
          (value) => {
            request.signal.removeEventListener("abort", cancelled);
            resolve(value);
          },
          (error: unknown) => {
            request.signal.removeEventListener("abort", cancelled);
            reject(
              error instanceof Error ? error : (
                new Error("Token refresh failed")
              ),
            );
          },
        );
      });
      check();
      if (!token) {
        throw new ApiError({ title: "Authentication Required", status: 401 });
      }
      request.headers.set("Authorization", `Bearer ${token}`);
    }
    request.signal.throwIfAborted();
    const response = await globalThis.fetch(request);
    check();
    return response;
  };
  return { controller, check, fetch };
};

let session = createSession(undefined);

/**
 * Registers the function used to retrieve the current access token.
 * Replacing or removing it ends the old session, including in-flight requests.
 */
export const setAccessTokenProvider = (
  provider: AccessTokenProvider | undefined,
) => {
  session.controller.abort();
  session = createSession(provider);
  client.setConfig({ fetch: session.fetch });
};

// Configure the base URL for all API requests
client.setConfig({
  baseUrl: `${env.VITE_API_BASE_PATH}/api/v0`,
  fetch: session.fetch,
});

// The generated client snapshots fetch before its first await. A request cannot
// adopt a new account even if the session changes before this interceptor runs.
client.interceptors.request.use((request, options) => {
  if (options.fetch !== session.fetch) {
    throw new DOMException("The authentication session changed.", "AbortError");
  }
  const current = session;
  const guardResponse =
    (callback: typeof options.responseValidator) => async (data: unknown) => {
      current.check();
      const result = callback ? await callback(data) : data;
      current.check();
      return result;
    };
  options.responseValidator = guardResponse(options.responseValidator);
  options.responseTransformer = guardResponse(options.responseTransformer);
  return new Request(request, {
    signal: AbortSignal.any([request.signal, current.controller.signal]),
  });
});

// Error interceptor — wraps RFC 7807 Problem Details responses into ApiError
client.interceptors.error.use(
  (error: unknown, response: Response | undefined, request) => {
    // The generated client also invokes this interceptor when fetch rejects.
    // Preserve cancellation/network failures rather than inventing an HTTP status.
    if (!response || response.ok) return error;
    // Error interceptors receive caller options, not the resolved configuration.
    // The request owns its original session signal even after body decoding.
    if (!request) throw new Error("API response has no request context");
    request.signal.throwIfAborted();
    let title = response.statusText || "Request failed";
    let detail: string | undefined;
    if (error && typeof error === "object") {
      if ("title" in error && typeof error.title === "string") {
        title = error.title;
      }
      if ("detail" in error && typeof error.detail === "string") {
        detail = error.detail;
      }
    }
    return new ApiError({
      title,
      detail,
      status: response.status,
    });
  },
);

export { client };
