// This source file is part of the Trove open-source project
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { expect, openNewStudyDialog, test } from "./fixtures";

test("marks the active document locale and returns focus after the locale dialogs", async ({
  researcherPage: page,
}, testInfo) => {
  const name = `Document locales ${Date.now()}-${testInfo.project.name}`;
  await openNewStudyDialog(page);
  await page.getByLabel("Study title").fill(name);
  await page.getByRole("button", { name: "Create study", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "Study configuration", exact: true }),
  ).toBeVisible();

  const trigger = (locale: string) =>
    page.getByRole("button", { name: `Documents ${locale}`, exact: true });
  const menu = page.getByRole("menu");
  const locale = (value: string) =>
    menu.getByRole("menuitemradio", { name: value, exact: true });

  // One locale: it is checked and offers no remove action.
  await trigger("en-US").click();
  await expect(locale("en-US")).toHaveAttribute("aria-checked", "true");
  await expect(menu.getByRole("menuitem", { name: /^Remove/ })).toHaveCount(0);

  // Closing the add dialog without adding returns focus to the trigger.
  await menu.getByRole("menuitem", { name: "Add locale", exact: true }).click();
  const addDialog = page.getByRole("dialog", { name: "Add a locale" });
  await expect(addDialog).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(addDialog).toBeHidden();
  await expect(trigger("en-US")).toBeFocused();

  // Adding a locale selects it and returns focus to the trigger.
  await page.keyboard.press("Enter");
  await menu.getByRole("menuitem", { name: "Add locale", exact: true }).click();
  await addDialog.getByRole("textbox", { name: /^Locale code/ }).fill("de-DE");
  await addDialog
    .getByRole("button", { name: "Add locale", exact: true })
    .click();
  await expect(addDialog).toBeHidden();
  await expect(trigger("de-DE")).toBeFocused();

  await page.keyboard.press("Enter");
  await expect(locale("de-DE")).toHaveAttribute("aria-checked", "true");
  await expect(locale("en-US")).toHaveAttribute("aria-checked", "false");
  for (const value of ["en-US", "de-DE"]) {
    await expect(
      menu.getByRole("menuitem", { name: `Remove ${value}`, exact: true }),
    ).toHaveCount(1);
  }

  // Selecting a locale checks it.
  await locale("en-US").click();
  await expect(menu).toBeHidden();
  await trigger("en-US").click();
  await expect(locale("en-US")).toHaveAttribute("aria-checked", "true");

  // Cancelling and confirming a removal both return focus to the trigger.
  await menu
    .getByRole("menuitem", { name: "Remove de-DE", exact: true })
    .click();
  const deleteDialog = page.getByRole("dialog", { name: "Deleting locale" });
  await expect(deleteDialog).toBeVisible();
  await deleteDialog.getByRole("button", { name: "Close" }).click();
  await expect(deleteDialog).toBeHidden();
  await expect(trigger("en-US")).toBeFocused();

  await page.keyboard.press("Enter");
  await menu
    .getByRole("menuitem", { name: "Remove de-DE", exact: true })
    .click();
  await deleteDialog
    .getByRole("button", { name: "Delete locale", exact: true })
    .click();
  await expect(deleteDialog).toBeHidden();
  await expect(trigger("en-US")).toBeFocused();
  await page.keyboard.press("Enter");
  await expect(locale("de-DE")).toHaveCount(0);
  await expect(locale("en-US")).toHaveAttribute("aria-checked", "true");
});
