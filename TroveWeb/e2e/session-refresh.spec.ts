// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import type { Request } from "@playwright/test";
import { z } from "zod";
import { expect, openNewStudyDialog, signInResearcher, test } from "./fixtures";

const isRefresh = (request: Request) =>
  request.method() === "POST" &&
  new URL(request.url()).pathname.endsWith("/protocol/openid-connect/token") &&
  new URLSearchParams(request.postData() ?? "").get("grant_type") ===
    "refresh_token";

test.describe("session renewal", () => {
  test.beforeEach(async ({ page }) => {
    // Install before Keycloak creates its expiry timer. Only browser time moves;
    // the disposable provider still issues and verifies real signed tokens.
    await page.clock.install();
    await signInResearcher(page);
    await expect(page.getByRole("button", { name: "User menu" })).toBeVisible();
    await expect(
      page.getByText("Schmiedmayer Lab", { exact: true }),
    ).toBeVisible();
  });

  test("renews through Keycloak and continues authenticated study authoring", async ({
    page,
  }, testInfo) => {
    const renewal = page.waitForResponse((response) =>
      isRefresh(response.request()),
    );
    // The development realm's access-token lifetime is 24 hours.
    await page.clock.fastForward("25:00:00");
    const renewed = await renewal;
    expect(renewed.status()).toBe(200);
    const { access_token: accessToken } = z
      .object({ access_token: z.string().min(1) })
      .parse(await renewed.json());
    await expect(page.getByRole("button", { name: "User menu" })).toBeVisible();

    const title = `Renewal E2E ${Date.now()}-${testInfo.project.name}`;
    await openNewStudyDialog(page);
    await page.getByLabel("Study title").fill(title);
    const created = page.waitForResponse(
      (response) =>
        response.request().method() === "POST" &&
        /^\/api\/v0\/groups\/[^/]+\/studies$/.test(
          new URL(response.url()).pathname,
        ),
    );
    await page.getByRole("button", { name: "Create study" }).click();
    const creation = await created;
    expect(creation.status()).toBe(201);
    // Keep credentials out of assertion output, including on failure.
    expect(
      (await creation.request().headerValue("authorization")) ===
        `Bearer ${accessToken}`,
      "Study creation must use the renewed bearer credential",
    ).toBe(true);
    await expect(
      page.getByRole("button", { name: title, exact: true }),
    ).toBeVisible();
    await expect(
      page.getByRole("button", { name: "Continue to sign in" }),
    ).toHaveCount(0);
  });

  for (const status of [400, 503]) {
    test(`closes the dashboard when renewal receives HTTP ${status}`, async ({
      page,
    }) => {
      await page.route("**/protocol/openid-connect/token", async (route) => {
        if (!isRefresh(route.request())) {
          await route.continue();
          return;
        }
        await route.fulfill({
          status,
          contentType: "application/json",
          body: JSON.stringify({
            error: status === 400 ? "invalid_grant" : "temporarily_unavailable",
          }),
        });
      });
      const renewal = page.waitForResponse((response) =>
        isRefresh(response.request()),
      );
      await page.clock.fastForward("25:00:00");
      expect((await renewal).status()).toBe(status);
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
  }
});
