// This source file is part of the Trove open-source project
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { expect, openNewStudyDialog, test } from "./fixtures";

const document = `## Your participation

Participation is **voluntary**.

| Measurement | Frequency |
| --- | --- |
| Heart rate | Daily |

<toggle id="agree" expected-value="true">I agree.<footnote>Ask questions first.</footnote></toggle>

<select id="contact" initial-value="email" expected-value="*">Contact method.<option id="email">Email</option><option id="phone">Phone</option></select>

<signature id="participant" />`;

test("combines enrollment settings and preserves consent through visual editing", async ({
  researcherPage: page,
}, testInfo) => {
  test.slow();
  const name = `Consent authoring ${Date.now()}-${testInfo.project.name}`;
  await openNewStudyDialog(page);
  await page.getByLabel("Study title").fill(name);
  await page.getByRole("button", { name: "Create study", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "Study configuration", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole("link", { name: "Home", exact: true }),
  ).toHaveCount(0);
  await expect(
    page.getByRole("link", { name: "Participation", exact: true }),
  ).toHaveCount(0);
  const components = page.getByRole("link", {
    name: "Components",
    exact: true,
  });
  await expect(components.locator("xpath=ancestor::ul")).toHaveCount(1);

  await page.getByRole("link", { name: "Enrollment", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "Participation criteria", exact: true }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Clear all criteria" }).click();
  await page.getByRole("radio", { name: /^Unlisted/ }).check();
  const savedEnrollment = page.waitForResponse(
    (response) =>
      response.request().method() === "PATCH" &&
      /\/studies\/[^/]+$/.test(response.url()),
  );
  await page.getByRole("button", { name: "Save", exact: true }).click();
  const enrollment = await savedEnrollment;
  expect(enrollment.status()).toBe(200);
  expect(enrollment.request().postDataJSON()).toMatchObject({
    visibility: "unlisted",
    enrollmentConditions: "none",
    participationCriterion: { type: "all", criteria: [] },
  });
  await page.reload();
  await expect(page.getByRole("radio", { name: /^Unlisted/ })).toBeChecked();

  await page.getByRole("link", { name: "Consent", exact: true }).click();
  await page
    .getByRole("textbox", { name: /^Consent title/ })
    .fill("Example consent");
  await page.getByRole("button", { name: "Markdown", exact: true }).click();
  const source = page.getByRole("textbox", {
    name: "Consent Markdown",
    exact: true,
  });
  await source.fill(document);
  await page.getByRole("button", { name: "Preview", exact: true }).click();
  await expect(page.getByRole("table")).toContainText("Heart rate");
  await expect(
    page.getByRole("region", {
      name: "Signature block: participant",
      exact: true,
    }),
  ).toBeVisible();
  await expect(
    page.getByRole("switch", { name: "Example toggle" }),
  ).toBeDisabled();
  await page
    .getByRole("button", { name: "Visual editor", exact: true })
    .click();
  await page.getByRole("button", { name: "Markdown", exact: true }).click();
  await expect(source).toHaveValue(document);

  // Focusing a table must not serialize a new trailing paragraph into the source.
  await page
    .getByRole("button", { name: "Visual editor", exact: true })
    .click();
  await page.getByRole("cell", { name: "Daily", exact: true }).click();
  await page.getByRole("button", { name: "Markdown", exact: true }).click();
  await expect(source).toHaveValue(document);

  await page
    .getByRole("button", { name: "Visual editor", exact: true })
    .click();
  const toggle = page.getByRole("region", {
    name: "Toggle: agree",
    exact: true,
  });
  await toggle
    .getByRole("combobox", { name: "Required response" })
    .selectOption("false");
  await toggle
    .locator(".ProseMirror")
    .first()
    .fill("I have read the document.");
  await page.getByRole("button", { name: "Markdown", exact: true }).click();
  const edited = await source.inputValue();
  expect(edited).toContain('id="agree" expected-value="false"');
  expect(edited).toContain("I have read the document.");
  expect(edited).toContain("<footnote>Ask questions first.</footnote>");
  expect(edited).toContain(
    '<select id="contact" initial-value="email" expected-value="*">',
  );
  expect(edited).toContain('<signature id="participant" />');
  await source.fill('<toggle id="unfinished">');
  await page.getByRole("button", { name: "Preview", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("not closed");
  await expect(source).toHaveValue('<toggle id="unfinished">');
  await source.fill(edited);
  await page
    .getByRole("button", { name: "Visual editor", exact: true })
    .click();
  await page
    .getByRole("button", { name: "Edit field ID: agree", exact: true })
    .click();
  const renameDialog = page.getByRole("dialog");
  await renameDialog
    .getByRole("textbox", { name: "Field ID", exact: true })
    .fill("participant");
  await renameDialog.getByRole("button", { name: "Apply ID" }).click();
  await expect(renameDialog.getByRole("alert")).toContainText("unique");
  await renameDialog
    .getByRole("textbox", { name: "Field ID", exact: true })
    .fill("agreement");
  await renameDialog.getByRole("button", { name: "Apply ID" }).click();
  await expect(
    page.getByRole("region", { name: "Toggle: agreement", exact: true }),
  ).toBeVisible();

  const selection = page.getByRole("region", {
    name: "Selection: contact",
    exact: true,
  });
  await selection
    .getByRole("combobox", { name: "Required response" })
    .selectOption("email");
  await selection
    .getByRole("button", { name: "Edit option ID: email", exact: true })
    .click();
  await renameDialog
    .getByRole("textbox", { name: "Option ID", exact: true })
    .fill("email-contact");
  await renameDialog.getByRole("button", { name: "Apply ID" }).click();
  await expect(
    selection.getByRole("combobox", { name: "Initial value" }),
  ).toHaveValue("email-contact");
  await expect(
    selection.getByRole("combobox", { name: "Required response" }),
  ).toHaveValue("email-contact");

  await page.getByRole("button", { name: "Add toggle", exact: true }).click();
  const added = page.getByRole("region", {
    name: "Toggle: toggle-1",
    exact: true,
  });
  await added
    .getByRole("button", { name: "Delete toggle", exact: true })
    .click();
  await page
    .getByRole("dialog")
    .getByRole("button", { name: "Cancel", exact: true })
    .click();
  await expect(added).toBeVisible();
  await added
    .getByRole("button", { name: "Delete toggle", exact: true })
    .click();
  await page
    .getByRole("dialog")
    .getByRole("button", { name: "Delete", exact: true })
    .click();
  await expect(added).toHaveCount(0);
  await page.getByRole("button", { name: "Markdown", exact: true }).click();
  const finalDocument = await source.inputValue();
  expect(finalDocument).toContain('id="agreement"');
  expect(finalDocument).toContain(
    'initial-value="email-contact" expected-value="email-contact"',
  );
  expect(finalDocument).toContain('<option id="email-contact">Email</option>');
  expect(finalDocument).toContain('<signature id="participant" />');
  const savedConsent = page.waitForResponse(
    (response) =>
      response.request().method() === "PATCH" &&
      /\/studies\/[^/]+$/.test(response.url()),
  );
  await page.getByRole("button", { name: "Save", exact: true }).click();
  expect((await savedConsent).status()).toBe(200);
  await page.reload();
  await page.getByRole("button", { name: "Markdown", exact: true }).click();
  await expect(source).toHaveValue(finalDocument);
});
