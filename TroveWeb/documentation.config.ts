// This source file is part of the Trove open-source project
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { defineConfig } from "@playwright/test";
import { documentationPort } from "./e2e/documentation-fixture";

// Playwright requires a default configuration export.
// eslint-disable-next-line import-x/no-default-export
export default defineConfig({
  testDir: "./e2e",
  testMatch: "documentation.capture.ts",
  workers: 1,
  retries: 0,
  timeout: 120_000,
  use: {
    baseURL: "http://localhost:3001",
    viewport: { width: 1440, height: 960 },
    locale: "en-US",
    timezoneId: "America/Los_Angeles",
    colorScheme: "light",
    // Authentication and consent payloads must not become traces or videos.
    trace: "off",
    video: "off",
  },
  webServer: {
    command: "npm run dev -- --host 127.0.0.1 --port 3001",
    port: 3001,
    reuseExistingServer: false,
    env: {
      VITE_API_BASE_PATH: `http://localhost:${documentationPort}`,
      VITE_KEYCLOAK_URL: "http://localhost:8180",
      VITE_KEYCLOAK_REALM: "trove",
      VITE_KEYCLOAK_CLIENT_ID: "trove-web",
    },
  },
});
