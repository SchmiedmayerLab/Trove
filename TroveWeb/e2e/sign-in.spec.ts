//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { expect, test } from "./fixtures";

test.describe("sign in", () => {
  test("signs out through Keycloak and protects the previous dashboard URL", async ({
    researcherPage: page,
  }) => {
    await expect(page.getByRole("button", { name: "User menu" })).toBeVisible();
    const dashboardURL = page.url();
    const logout = page.waitForRequest(
      (request) =>
        request.method() === "POST" &&
        new URL(request.url()).pathname.endsWith(
          "/protocol/openid-connect/logout",
        ),
    );
    await page.getByRole("button", { name: "User menu" }).click();
    await page.getByRole("menuitem", { name: "Sign out" }).click();
    expect(
      new URL((await logout).url()).searchParams.has("id_token_hint"),
    ).toBe(false);
    // The POST commits a new document before its application modules finish loading.
    await page.waitForURL(new URL("/sign-in", dashboardURL).href, {
      waitUntil: "load",
    });
    await expect(
      page.getByRole("button", { name: "Sign into the dashboard" }),
    ).toBeVisible();
    await page.goto(dashboardURL);
    await expect(
      page.getByRole("button", { name: "Sign into the dashboard" }),
    ).toBeVisible();
    await expect(page.getByRole("button", { name: "User menu" })).toHaveCount(
      0,
    );
    await page.getByRole("button", { name: "Sign into the dashboard" }).click();
    await expect(page.locator("#username")).toBeVisible();
  });

  test("keeps the dashboard closed if logout navigation is canceled", async ({
    researcherPage: page,
  }) => {
    await expect(page.getByRole("button", { name: "User menu" })).toBeVisible();
    // Cancel the navigation itself so the existing document remains active.
    await page.route("**/protocol/openid-connect/logout*", (route) =>
      route.abort("aborted"),
    );
    await page.getByRole("button", { name: "User menu" }).click();
    await page.getByRole("menuitem", { name: "Sign out" }).click();
    await expect(
      page.getByText("Your session ended or its permissions changed."),
    ).toBeVisible();
    await expect(
      page.getByRole("button", { name: "Continue to sign in" }),
    ).toBeVisible();
    await expect(page.getByRole("button", { name: "User menu" })).toHaveCount(
      0,
    );
    await expect(
      page.getByRole("link", { name: "Components", exact: true }),
    ).toHaveCount(0);
  });

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
