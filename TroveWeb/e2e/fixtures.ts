//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { createHash } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import { test as base } from "@playwright/test";

const OUTPUT_DIRECTORY = ".nyc_output";

/**
 * Writes the counters the instrumented bundle accumulated during a test, for `nyc` to merge.
 * Without `COVERAGE=true` the application is not instrumented and this does nothing, so the
 * same specs run either way.
 */
export const test = base.extend({
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
});

export { expect } from "@playwright/test";
