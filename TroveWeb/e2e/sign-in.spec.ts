//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { expect, test } from "./fixtures";

test.describe("sign in", () => {
  test("shows the landing page to a signed-out visitor", async ({ page }) => {
    await page.goto("/");

    await expect(page.getByText("Welcome")).toBeVisible();
    await expect(
      page.getByRole("button", { name: /sign into the dashboard/i }),
    ).toBeVisible();
  });

  test("keeps a signed-out visitor away from the dashboard", async ({
    page,
  }) => {
    await page.goto("/some-group");

    // The dashboard is never rendered without a session; the visitor lands back on sign-in.
    await expect(
      page.getByRole("button", { name: /sign into the dashboard/i }),
    ).toBeVisible();
  });

  test("hands off to Keycloak when signing in", async ({ page }) => {
    await page.goto("/");
    await page
      .getByRole("button", { name: /sign into the dashboard/i })
      .click();

    await page.waitForURL(/\/realms\/trove\/protocol\/openid-connect\/auth/, {
      timeout: 30_000,
    });
    await expect(
      page.locator("#username, input[name='username']"),
    ).toBeVisible();
  });
});
