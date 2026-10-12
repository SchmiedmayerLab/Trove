//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { createHash } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import { expect, test as base, type Page } from "@playwright/test";

const OUTPUT_DIRECTORY = ".nyc_output";

interface Fixtures {
  researcherPage: Page;
}

export const signInResearcher = async (page: Page) => {
  const password = process.env.KEYCLOAK_DEV_PASSWORD;
  if (!password) {
    throw new Error(
      "KEYCLOAK_DEV_PASSWORD is required for authenticated end-to-end tests",
    );
  }

  await page.goto("/");
  const applicationOrigin = new URL(page.url()).origin;
  await page.getByRole("button", { name: "Sign into the dashboard" }).click();
  await page
    .locator("#username")
    .fill(process.env.KEYCLOAK_DEV_USER ?? "leland@example.com");
  await page.locator("#password").fill(password);
  await page.locator("#kc-login").click();
  await page.waitForURL((url) => url.origin === applicationOrigin);
};

export const openNewStudyDialog = async (page: Page) => {
  const firstStudyButton = page.getByRole("button", { name: "Create study" });
  const studySelector = page.locator("[data-element='header-selector']").nth(1);
  await expect(firstStudyButton.or(studySelector)).toBeVisible();
  if (await firstStudyButton.isVisible()) {
    await firstStudyButton.click();
    return;
  }

  await studySelector.click();
  await page.getByText("Add study", { exact: true }).click();
};

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
  researcherPage: async ({ page }, runTest) => {
    await signInResearcher(page);
    await runTest(page);
  },
});

export { expect } from "@playwright/test";
