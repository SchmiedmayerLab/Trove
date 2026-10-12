// This source file is part of the Trove open-source project
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { execFileSync } from "node:child_process";
import { mkdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { expect, test } from "@playwright/test";
import { seedDocumentationStudy } from "./documentation-fixture";

test("capture the synthetic researcher walkthrough", async ({
  page,
}, testInfo) => {
  const seeded = await seedDocumentationStudy();
  const password = process.env.KEYCLOAK_DEV_PASSWORD;
  if (!password) throw new Error("KEYCLOAK_DEV_PASSWORD is required");
  const root = fileURLToPath(new URL("../../", import.meta.url));
  const output = `${root}/docs/images/web`;
  await mkdir(output, { recursive: true });
  const capture = async (name: string, title: string) => {
    await page.setViewportSize({ width: 1440, height: 960 });
    await page.evaluate(() => document.fonts.ready);
    if (["enrollment", "consent", "consent-editor"].includes(name)) {
      // Resize the real viewport, not just the screenshot canvas: fixed navigation
      // must remain attached to the window while the complete form stays visible.
      const height = await page.evaluate(
        () => document.documentElement.scrollHeight,
      );
      await page.setViewportSize({
        width: 1440,
        height: Math.max(960, height),
      });
      await expect
        .poll(() =>
          page.evaluate(
            () => document.documentElement.scrollHeight <= window.innerHeight,
          ),
        )
        .toBe(true);
    }
    await page.evaluate(() => window.scrollTo(0, 0));
    await page.mouse.move(0, 0);
    await expect(page.locator("[data-sonner-toast]")).toHaveCount(0, {
      timeout: 10_000,
    });
    for (const appearance of ["light", "dark"] as const) {
      await page.emulateMedia({ colorScheme: appearance });
      await expect(
        page.locator("[data-grove-color-scheme]").first(),
      ).toHaveAttribute("data-grove-color-scheme", appearance);
      // Body-level portals must inherit the same palette as the app content.
      const palettes = await page.evaluate(() => {
        const provider = document.querySelector("[data-grove-color-scheme]");
        if (!provider) throw new Error("Missing appearance provider");
        return {
          root: getComputedStyle(document.documentElement).getPropertyValue(
            "--color-bg",
          ),
          app: getComputedStyle(provider).getPropertyValue("--color-bg"),
        };
      });
      expect(palettes.root).toBe(palettes.app);
      await expect
        .poll(async () => {
          const footer = await page
            .locator('[data-slot="sidebar-footer"]')
            .boundingBox();
          const viewport = page.viewportSize();
          if (!footer || !viewport) throw new Error("Missing sidebar geometry");
          return Math.abs(footer.y + footer.height - viewport.height);
        })
        .toBeLessThanOrEqual(1);
      const suffix = appearance === "dark" ? "~dark" : "";
      const raw = testInfo.outputPath(`${name}${suffix}.png`);
      await page.screenshot({
        path: raw,
        animations: "disabled",
        fullPage: false,
      });
      execFileSync("/usr/bin/swift", [
        `${root}/scripts/frame-screenshot.swift`,
        raw,
        `${output}/${name}${suffix}.png`,
        title,
        appearance,
      ]);
    }
    await page.emulateMedia({ colorScheme: "light" });
  };

  await page.goto("/");
  await page.getByRole("button", { name: "Sign into the dashboard" }).click();
  await page
    .getByRole("textbox", { name: "Email", exact: true })
    .fill("leland@example.com");
  await page
    .getByRole("textbox", { name: "Password", exact: true })
    .fill(password);
  await page.getByRole("button", { name: "Sign In", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Daily Activity Study", exact: true }),
  ).toBeVisible();

  for (const [route, heading, name, title] of [
    ["general", "General", "study-details", "Study Details"],
    ["enrollment", "Enrollment", "enrollment", "Enrollment Settings"],
    ["consent", "Consent", "consent", "Consent Authoring"],
  ] as const) {
    await page.goto(
      `/${seeded.groupId}/${seeded.studyId}/configuration/${route}`,
    );
    await expect(
      page.getByRole("heading", { name: heading, exact: true }),
    ).toBeVisible();
    await capture(name, title);
  }
  await page
    .getByRole("button", { name: "Visual editor", exact: true })
    .click();
  await capture("consent-editor", "Visual Consent Editor");
  await page.getByRole("button", { name: "Publish", exact: true }).click();
  await page
    .getByRole("button", { name: "Validate draft", exact: true })
    .click();
  await expect(
    page.getByRole("heading", { name: "Review publication candidate" }),
  ).toBeVisible();
  await capture("publication", "Publication Review");
  await page.getByRole("button", { name: "Publish v1", exact: true }).click();
  await expect(
    page.getByText("Study published (v1)", { exact: true }),
  ).toBeVisible();

  // Leave these additions as a draft: mobile captures review published revision 1.
  await page.getByRole("link", { name: "Components", exact: true }).click();
  await page
    .getByRole("button", { name: "Create component", exact: true })
    .click();
  await expect(
    page.getByRole("heading", { name: "Choose a component type" }),
  ).toBeVisible();
  await capture("component-types", "Study Components");
  await page
    .getByRole("link", { name: "Create component", exact: true })
    .click();
  await page.getByRole("textbox", { name: /^Name\b/ }).fill("Welcome");
  await page
    .getByRole("textbox", { name: /^Title\b/ })
    .fill("Welcome to the study");
  await page
    .getByRole("textbox", { name: /^Lede\b/ })
    .fill("Your participation, at a glance");
  await page
    .locator(".ProseMirror")
    .fill(
      "Thank you for helping us understand everyday movement and wellbeing.\n\nReview the consent document before sharing any health data. You can manage Health access on your device and withdraw from the study at any time.\n\nThis demonstration uses synthetic data only.",
    );
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await page.getByRole("link", { name: "Welcome", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "Edit component", exact: true }),
  ).toBeVisible();
  await capture("information", "Participant Information");
  await page.getByRole("button", { name: "Add schedule", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "Schedule", exact: true }),
  ).toBeVisible();
  await capture("schedule", "Component Schedule");
});
