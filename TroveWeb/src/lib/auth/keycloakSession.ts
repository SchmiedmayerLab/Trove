// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import type Keycloak from "keycloak-js";
import { parseGroupMemberships, type GroupRole } from "./groupMemberships";
import { setAccessTokenProvider } from "../api/client";

export interface AuthUser {
  name: string;
  email: string;
  groupMemberships: Record<string, GroupRole>;
}

export type SessionKeycloak = Pick<
  Keycloak,
  | "authenticated"
  | "token"
  | "tokenParsed"
  | "updateToken"
  | "clearToken"
  | "onAuthSuccess"
  | "onAuthError"
  | "onAuthLogout"
  | "onAuthRefreshSuccess"
  | "onAuthRefreshError"
  | "onTokenExpired"
>;

const strings = (value: unknown): string[] | null => {
  if (value === undefined) return [];
  if (!Array.isArray(value) || !value.every((item) => typeof item === "string"))
    return null;
  // eslint-disable-next-line sonarjs/no-alphabetical-sort -- Claim identifiers need exact, locale-independent ordering.
  return [...new Set(value)].sort();
};

const snapshot = (keycloak: SessionKeycloak) => {
  const token = keycloak.tokenParsed;
  if (
    !keycloak.authenticated ||
    typeof keycloak.token !== "string" ||
    !keycloak.token ||
    !token ||
    typeof token.iss !== "string" ||
    !token.iss ||
    typeof token.sub !== "string" ||
    !token.sub
  )
    return null;
  const groups = strings(token.groups);
  const audience = strings(
    typeof token.aud === "string" ? [token.aud] : token.aud,
  );
  const realm: unknown = token.realm_access;
  let realmRoles: unknown;
  if (realm !== undefined) {
    if (!realm || typeof realm !== "object" || !("roles" in realm)) return null;
    realmRoles = realm.roles;
  }
  const roles = strings(realmRoles);
  if (!groups || !audience?.length || !roles) return null;
  const fullName = [token.given_name, token.family_name]
    .filter(
      (part: unknown): part is string =>
        typeof part === "string" && part.length > 0,
    )
    .join(" ");
  const preferredName =
    typeof token.preferred_username === "string" ?
      token.preferred_username
    : "";
  const user: AuthUser = {
    name: fullName || preferredName || "User",
    email: typeof token.email === "string" ? token.email : "",
    groupMemberships: parseGroupMemberships(groups),
  };
  return {
    authority: JSON.stringify([token.iss, token.sub, audience, roles, groups]),
    user,
  };
};

/** Owns one dashboard lifetime; an authority change requires a fresh page. */
export const bindKeycloakSession = (
  keycloak: SessionKeycloak,
  callbacks: {
    clearCache: () => void;
    onUser: (user: AuthUser | null) => void;
    onEnded: () => void;
  },
) => {
  let accepted: string | undefined;
  let ended = false;
  let disposed = false;
  setAccessTokenProvider(undefined);
  callbacks.clearCache();

  const end = () => {
    if (disposed) return;
    if (ended) {
      // Keycloak can complete an old refresh after clearToken().
      if (keycloak.token) keycloak.clearToken();
      return;
    }
    ended = true;
    accepted = undefined;
    setAccessTokenProvider(undefined);
    keycloak.clearToken();
    callbacks.onUser(null);
    callbacks.onEnded();
    callbacks.clearCache();
  };

  const synchronize = (allowStart = true) => {
    if (disposed) return;
    if (ended) {
      end();
      return;
    }
    const current = snapshot(keycloak);
    if (!current) {
      if (accepted || keycloak.authenticated) end();
      else callbacks.onUser(null);
      return;
    }
    if (accepted && accepted !== current.authority) {
      end();
      return;
    }
    if (!accepted) {
      if (!allowStart) return;
      accepted = current.authority;
      setAccessTokenProvider(refresh);
    }
    callbacks.onUser(current.user);
  };

  const requireActive = () => {
    if (disposed || ended || !accepted)
      throw new DOMException("The session has ended.", "AbortError");
  };

  const refresh = async () => {
    requireActive();
    try {
      await keycloak.updateToken(30);
    } catch (error) {
      end();
      throw error;
    }
    synchronize(false);
    requireActive();
    return keycloak.token;
  };

  const handlers = {
    onAuthSuccess: () => synchronize(),
    onAuthError: () => {
      if (accepted) end();
    },
    onAuthLogout: () => {
      if (accepted || ended) end();
    },
    onAuthRefreshSuccess: () => synchronize(false),
    onAuthRefreshError: () => {
      if (accepted || ended) end();
    },
    onTokenExpired: () => {
      if (accepted) void refresh().catch(end);
    },
  };
  const names = [
    "onAuthSuccess",
    "onAuthError",
    "onAuthLogout",
    "onAuthRefreshSuccess",
    "onAuthRefreshError",
    "onTokenExpired",
  ] as const;
  for (const name of names) keycloak[name] = handlers[name];

  return {
    synchronize,
    end,
    dispose: () => {
      if (disposed) return;
      disposed = true;
      const ownsHandlers = keycloak.onAuthSuccess === handlers.onAuthSuccess;
      for (const name of names) {
        if (keycloak[name] === handlers[name]) keycloak[name] = undefined;
      }
      if (ownsHandlers) {
        setAccessTokenProvider(undefined);
        callbacks.clearCache();
      }
    },
  };
};
