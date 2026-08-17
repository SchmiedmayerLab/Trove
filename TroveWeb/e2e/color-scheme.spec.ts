//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { expect, test } from "./fixtures";

// The provider resolves the scheme and the palette supplies the values. Both halves have been
// broken before: the provider defaulted to light, and the semantic tokens were baked into the
// utilities at build time so overriding them had no effect.
test.describe("colour scheme", () => {
  test("follows an operating system set to dark", async ({ page }) => {
    await page.emulateMedia({ colorScheme: "dark" });
    await page.goto("/");

    const themed = page.locator("[data-grove-color-scheme]").first();
    await expect(themed).toHaveAttribute("data-grove-color-scheme", "dark");
    await expect(themed).toHaveAttribute(
      "data-grove-color-scheme-preference",
      "system",
    );

    const background = await page
      .locator(".grid.h-svh")
      .first()
      .evaluate((element) => getComputedStyle(element).backgroundColor);
    expect(parseLightness(background)).toBeLessThan(0.5);
  });

  test("follows an operating system set to light", async ({ page }) => {
    await page.emulateMedia({ colorScheme: "light" });
    await page.goto("/");

    const themed = page.locator("[data-grove-color-scheme]").first();
    await expect(themed).toHaveAttribute("data-grove-color-scheme", "light");

    const background = await page
      .locator(".grid.h-svh")
      .first()
      .evaluate((element) => getComputedStyle(element).backgroundColor);
    expect(parseLightness(background)).toBeGreaterThan(0.5);
  });
});

/** Reads the lightness out of an `oklch(...)` or `rgb(...)` colour, normalised to 0–1. */
const parseLightness = (color: string): number => {
  const oklch = /oklch\(\s*([\d.]+)(%?)/.exec(color);
  if (oklch) {
    const value = Number(oklch[1]);
    return oklch[2] === "%" ? value / 100 : value;
  }
  const rgb = /rgba?\(\s*(\d+)[,\s]+(\d+)[,\s]+(\d+)/.exec(color);
  if (rgb) {
    const [red, green, blue] = rgb.slice(1, 4).map(Number);
    return (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255;
  }
  throw new Error(`could not read a lightness out of ${color}`);
};
