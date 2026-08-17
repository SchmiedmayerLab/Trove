//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Keycloak from "keycloak-js";
import { env } from "../env";

let keycloakInstance: Keycloak | undefined;
let initPromise: Promise<boolean> | undefined;

const E2E_SESSION_STORAGE_KEY = "trove:e2e-keycloak-session";

interface E2EKeycloakSession {
  token: string;
  refreshToken?: string;
  idToken?: string;
}

/**
 * Reads a session injected by the Playwright suite. This is deliberately limited to Vite's
 * development build, so deployed bundles can only authenticate through Keycloak's normal flow.
 */
const readE2EKeycloakSession = (): E2EKeycloakSession | undefined => {
  if (!import.meta.env.DEV) return undefined;

  const serialized = window.sessionStorage.getItem(E2E_SESSION_STORAGE_KEY);
  if (!serialized) return undefined;

  try {
    const session = JSON.parse(serialized) as Partial<E2EKeycloakSession>;
    return typeof session.token === "string" ?
        {
          token: session.token,
          ...(typeof session.refreshToken === "string" && {
            refreshToken: session.refreshToken,
          }),
          ...(typeof session.idToken === "string" && {
            idToken: session.idToken,
          }),
        }
      : undefined;
  } catch {
    return undefined;
  }
};

/**
 * Returns the shared Keycloak instance, creating it on the first call.
 */
export const getKeycloak = (): Keycloak => {
  keycloakInstance ??= new Keycloak({
    url: String(env.VITE_KEYCLOAK_URL),
    realm: String(env.VITE_KEYCLOAK_REALM),
    clientId: String(env.VITE_KEYCLOAK_CLIENT_ID),
  });
  return keycloakInstance;
};

/**
 * Initializes Keycloak with `check-sso` so existing sessions are picked up
 * without forcing a login redirect. Safe to call multiple times — the init
 * promise is shared so Keycloak is only initialized once.
 */
export const initKeycloak = async (): Promise<boolean> => {
  if (!initPromise) {
    const keycloak = getKeycloak();
    const e2eSession = readE2EKeycloakSession();
    initPromise = keycloak.init({
      onLoad: "check-sso",
      silentCheckSsoRedirectUri: `${window.location.origin}${import.meta.env.BASE_URL}silent-check-sso.html`,
      checkLoginIframe: false,
      ...e2eSession,
    });
  }
  return initPromise;
};
