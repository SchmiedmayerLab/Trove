//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { createHash } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import { test as base, type Page } from "@playwright/test";

const OUTPUT_DIRECTORY = ".nyc_output";
const E2E_SESSION_STORAGE_KEY = "trove:e2e-keycloak-session";

interface KeycloakTokenResponse {
  access_token: string;
  refresh_token?: string;
  id_token?: string;
}

interface Fixtures {
  researcherPage: Page;
}

/**
 * Writes the counters the instrumented bundle accumulated during a test, for `nyc` to merge.
 * Without `COVERAGE=true` the application is not instrumented and this does nothing, so the
 * same specs run either way.
 */
export const test = base.extend<Fixtures>({
  page: async ({ page }, runTest, testInfo) => {
    await runTest(page);

    if (process.env.COVERAGE !== "true") {
      return;
    }

    const coverage = await page
      .evaluate(() => (window as { __coverage__?: unknown }).__coverage__)
      .catch(() => undefined);
    if (!coverage) {
      return;
    }

    await mkdir(OUTPUT_DIRECTORY, { recursive: true });
    const name = createHash("sha256")
      .update(`${testInfo.titlePath.join(" ")}${testInfo.repeatEachIndex}`)
      .digest("hex")
      .slice(0, 16);
    await writeFile(
      `${OUTPUT_DIRECTORY}/playwright-${name}.json`,
      JSON.stringify(coverage),
    );
  },
  researcherPage: async ({ page, request }, runTest) => {
    const keycloakUrl = process.env.KEYCLOAK_URL ?? "http://localhost:8180";
    const realm = process.env.KEYCLOAK_REALM ?? "trove";
    const password = process.env.KEYCLOAK_DEV_PASSWORD;
    if (!password) {
      throw new Error(
        "KEYCLOAK_DEV_PASSWORD is required for authenticated end-to-end tests",
      );
    }
    const response = await request.post(
      `${keycloakUrl}/realms/${realm}/protocol/openid-connect/token`,
      {
        form: {
          client_id: process.env.KEYCLOAK_DEV_CLIENT ?? "trove-dev-cli",
          grant_type: "password",
          username: process.env.KEYCLOAK_DEV_USER ?? "leland@example.com",
          password,
          scope: "openid",
        },
      },
    );

    if (!response.ok()) {
      throw new Error(
        `Could not mint the researcher token (${response.status()}): ${await response.text()}`,
      );
    }

    const tokens = (await response.json()) as KeycloakTokenResponse;
    await page.addInitScript(
      ({ storageKey, session }) => {
        window.sessionStorage.setItem(storageKey, JSON.stringify(session));
      },
      {
        storageKey: E2E_SESSION_STORAGE_KEY,
        session: {
          token: tokens.access_token,
          refreshToken: tokens.refresh_token,
          idToken: tokens.id_token,
        },
      },
    );

    await runTest(page);
  },
});

export { expect } from "@playwright/test";
