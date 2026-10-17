// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { QueryClient } from "@tanstack/react-query";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  bindKeycloakSession,
  type AuthUser,
  type SessionKeycloak,
} from "./keycloakSession";
import { client } from "../api/client";

vi.mock("../env", () => ({
  env: { VITE_API_BASE_PATH: "https://api.example.test" },
}));

const bindings: Array<ReturnType<typeof bindKeycloakSession>> = [];
const keycloakFixture = (): SessionKeycloak => {
  const keycloak: SessionKeycloak = {
    authenticated: true,
    token: "initial-token",
    tokenParsed: {
      iss: "https://identity.example.test/realms/trove",
      sub: "researcher-1",
      aud: "trove-api",
      given_name: "Jane",
      family_name: "Researcher",
      email: "jane@example.test",
      realm_access: { roles: ["trove-researcher"] },
      groups: ["/Lab/admin", "/Lab/researcher"],
    },
    updateToken: vi
      .fn<SessionKeycloak["updateToken"]>()
      .mockResolvedValue(false),
    clearToken: () => {
      const hadToken = keycloak.token !== undefined;
      keycloak.authenticated = false;
      keycloak.token = undefined;
      keycloak.tokenParsed = undefined;
      if (hadToken) keycloak.onAuthLogout?.();
    },
  };
  return keycloak;
};

const setup = (keycloak = keycloakFixture()) => {
  const cache = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  });
  const onUser = vi.fn<(user: AuthUser | null) => void>();
  const onEnded = vi.fn<() => void>();
  const binding = bindKeycloakSession(keycloak, {
    clearCache: () => cache.clear(),
    onUser,
    onEnded,
  });
  bindings.push(binding);
  const requests: Request[] = [];
  vi.stubGlobal("fetch", (input: RequestInfo | URL, init?: RequestInit) => {
    requests.push(new Request(input, init));
    return Promise.resolve(
      new Response(JSON.stringify({ value: "current" }), {
        headers: { "Content-Type": "application/json" },
      }),
    );
  });
  return { keycloak, cache, binding, onUser, onEnded, requests };
};

afterEach(() => {
  for (const binding of bindings.splice(0).reverse()) binding.dispose();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

describe("Keycloak session lifetime", () => {
  it("allows signed-out initialization without ending or authenticating a session", () => {
    const keycloak = keycloakFixture();
    keycloak.clearToken();
    const { binding, onUser, onEnded } = setup(keycloak);
    keycloak.onAuthLogout?.();
    binding.synchronize();
    expect(onUser).toHaveBeenLastCalledWith(null);
    expect(onEnded).not.toHaveBeenCalled();
  });

  it("installs the token provider and publishes the initial user", async () => {
    const { keycloak, binding, onUser, onEnded, requests } = setup();
    binding.synchronize();
    await client.get({ url: "/fixture", throwOnError: true });
    expect(keycloak.updateToken).toHaveBeenCalledWith(30);
    expect(requests[0]?.headers.get("Authorization")).toBe(
      "Bearer initial-token",
    );
    expect(onUser).toHaveBeenLastCalledWith({
      name: "Jane Researcher",
      email: "jane@example.test",
      groupMemberships: { Lab: "admin" },
    });
    expect(onEnded).not.toHaveBeenCalled();
  });

  it("updates display claims on routine refresh without resetting requests or cached data", async () => {
    const { keycloak, binding, cache, onUser, onEnded, requests } = setup();
    binding.synchronize();
    cache.setQueryData(["private"], "existing");
    vi.mocked(keycloak.updateToken).mockImplementation(() => {
      keycloak.token = "refreshed-token";
      keycloak.tokenParsed = {
        ...keycloak.tokenParsed,
        given_name: "Updated",
        exp: 9999999999,
        groups: ["/Lab/researcher", "/Lab/admin", "/Lab/admin"],
      };
      keycloak.onAuthRefreshSuccess?.();
      return Promise.resolve(true);
    });
    await client.get({ url: "/fixture", throwOnError: true });
    expect(onUser).toHaveBeenLastCalledWith(
      expect.objectContaining({ name: "Updated Researcher" }),
    );
    expect(requests[0]?.headers.get("Authorization")).toBe(
      "Bearer refreshed-token",
    );
    expect(cache.getQueryData(["private"])).toBe("existing");
    expect(onEnded).not.toHaveBeenCalled();
  });

  it.each(["onAuthLogout", "onAuthRefreshError", "onAuthError"] as const)(
    "%s closes requests, credentials and cached data together",
    async (event) => {
      const { keycloak, binding, cache, onUser, onEnded, requests } = setup();
      binding.synchronize();
      cache.setQueryData(["private"], "old-data");
      keycloak[event]?.();
      expect(keycloak.authenticated).toBe(false);
      expect(keycloak.token).toBeUndefined();
      expect(cache.getQueryData(["private"])).toBeUndefined();
      expect(onUser).toHaveBeenLastCalledWith(null);
      expect(onEnded).toHaveBeenCalledTimes(1);
      await client.get({ url: "/fixture", throwOnError: true });
      expect(requests[0]?.headers.get("Authorization")).toBeNull();
    },
  );

  it.each([
    { sub: "other-researcher" },
    { iss: "https://other.example.test" },
    { aud: "other-api" },
    { groups: ["/Lab/researcher"] },
    { realm_access: { roles: [] } },
  ])("ends the session when authority changes: %j", (changes) => {
    const { keycloak, binding, cache, onEnded } = setup();
    binding.synchronize();
    cache.setQueryData(["private"], "old-data");
    keycloak.tokenParsed = { ...keycloak.tokenParsed, ...changes };
    keycloak.onAuthRefreshSuccess?.();
    expect(onEnded).toHaveBeenCalledTimes(1);
    expect(cache.getQueryData(["private"])).toBeUndefined();
    expect(keycloak.token).toBeUndefined();
  });

  it.each([
    { iss: "" },
    { sub: "" },
    { aud: undefined },
    { aud: [] },
    { groups: false },
    { groups: [null] },
    { realm_access: null },
  ])("rejects malformed authority claims at initialization: %j", (changes) => {
    const keycloak = keycloakFixture();
    // Model malformed decoded token data without asserting that it is a valid claim type.
    Object.assign(keycloak.tokenParsed ?? {}, changes);
    const { binding, onEnded } = setup(keycloak);
    binding.synchronize();
    expect(onEnded).toHaveBeenCalledTimes(1);
    expect(keycloak.token).toBeUndefined();
  });

  it("does not resurrect credentials when an old refresh finishes after logout", async () => {
    const { keycloak, binding, cache, onUser, onEnded } = setup();
    const oldClaims = keycloak.tokenParsed;
    let finish: () => void = vi.fn();
    let announce: () => void = vi.fn();
    const started = new Promise<void>((resolve) => {
      announce = resolve;
    });
    const refresh = new Promise<boolean>((resolve) => {
      finish = () => resolve(true);
    });
    vi.mocked(keycloak.updateToken).mockImplementation(() => {
      announce();
      return refresh;
    });
    binding.synchronize();
    const pending = client.get({ url: "/fixture", throwOnError: true });
    const rejected = expect(pending).rejects.toMatchObject({
      name: "AbortError",
    });
    await started;
    binding.end();
    await rejected;
    keycloak.authenticated = true;
    keycloak.token = "late-token";
    keycloak.tokenParsed = oldClaims;
    keycloak.onAuthRefreshSuccess?.();
    finish();
    await refresh;
    expect(keycloak.token).toBeUndefined();
    expect(keycloak.authenticated).toBe(false);
    expect(cache.getQueryCache().getAll()).toHaveLength(0);
    expect(onEnded).toHaveBeenCalledTimes(1);
    expect(onUser).toHaveBeenLastCalledWith(null);
  });

  it("closes the session when expiry-driven refresh fails", async () => {
    const { keycloak, binding, onEnded } = setup();
    binding.synchronize();
    vi.mocked(keycloak.updateToken).mockRejectedValue(new Error("Offline"));
    keycloak.onTokenExpired?.();
    await vi.waitFor(() => expect(onEnded).toHaveBeenCalledTimes(1));
    expect(keycloak.token).toBeUndefined();
  });

  it("does not adopt a different account through a new authentication callback", () => {
    const { keycloak, binding, cache, onEnded } = setup();
    binding.synchronize();
    cache.setQueryData(["private"], "old-data");
    keycloak.tokenParsed = { ...keycloak.tokenParsed, sub: "other-account" };
    keycloak.onAuthSuccess?.();
    expect(onEnded).toHaveBeenCalledTimes(1);
    expect(keycloak.authenticated).toBe(false);
    expect(cache.getQueryData(["private"])).toBeUndefined();
  });

  it("does not let an ignored network cancellation repopulate the cleared query cache", async () => {
    const { binding, cache } = setup();
    binding.synchronize();
    let announce: () => void = vi.fn();
    let finish: () => void = vi.fn();
    let respond: (response: Response) => void = vi.fn();
    const started = new Promise<void>((resolve) => {
      announce = resolve;
    });
    const completed = new Promise<void>((resolve) => {
      finish = resolve;
    });
    const response = new Promise<Response>((resolve) => {
      respond = resolve;
    });
    vi.stubGlobal("fetch", () => {
      announce();
      return response;
    });
    const pending = cache.query({
      queryKey: ["private"],
      queryFn: async () => {
        try {
          return await client.get({ url: "/fixture", throwOnError: true });
        } finally {
          finish();
        }
      },
    });
    const rejected = expect(pending).rejects.toBeDefined();
    await started;
    binding.end();
    await rejected;
    respond(
      new Response(JSON.stringify({ secret: "old-session" }), {
        headers: { "Content-Type": "application/json" },
      }),
    );
    await completed;
    expect(cache.getQueryData(["private"])).toBeUndefined();
    expect(cache.getQueryCache().getAll()).toHaveLength(0);
  });

  it("closes credentials and the UI even if cache cleanup fails", () => {
    const keycloak = keycloakFixture();
    let failCleanup = false;
    const failure = new Error("Cache cleanup failed");
    const onEnded = vi.fn();
    const binding = bindKeycloakSession(keycloak, {
      clearCache: () => {
        if (failCleanup) throw failure;
      },
      onUser: vi.fn(),
      onEnded,
    });
    bindings.push(binding);
    binding.synchronize();
    failCleanup = true;
    try {
      expect(() => binding.end()).toThrow(failure);
      expect(keycloak.token).toBeUndefined();
      expect(keycloak.authenticated).toBe(false);
      expect(onEnded).toHaveBeenCalledTimes(1);
    } finally {
      failCleanup = false;
    }
  });

  it("does not let old cleanup or initialization detach a replacement binding", async () => {
    const keycloak = keycloakFixture();
    const first = setup(keycloak);
    first.binding.synchronize();
    const current = setup(keycloak);
    current.binding.synchronize();
    current.cache.setQueryData(["private"], "current");
    first.binding.dispose();
    first.binding.synchronize();
    await client.get({ url: "/fixture", throwOnError: true });
    expect(current.requests[0]?.headers.get("Authorization")).toBe(
      "Bearer initial-token",
    );
    expect(current.cache.getQueryData(["private"])).toBe("current");
    keycloak.onAuthLogout?.();
    expect(current.onEnded).toHaveBeenCalledTimes(1);
  });
});
