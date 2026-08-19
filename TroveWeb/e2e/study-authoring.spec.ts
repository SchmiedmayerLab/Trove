//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import type { Page } from "@playwright/test";
import { expect, test } from "./fixtures";

const questionnaire = JSON.stringify({
  resourceType: "Questionnaire",
  id: "wellbeing-questionnaire",
  language: "en-US",
  title: "Daily wellbeing",
  status: "active",
  item: [
    {
      linkId: "wellbeing",
      text: "How are you feeling today?",
      type: "string",
    },
  ],
});

const openNewStudyDialog = async (page: Page) => {
  const firstStudyButton = page.getByRole("button", { name: "Create study" });
  if (await firstStudyButton.isVisible()) {
    await firstStudyButton.click();
    return;
  }

  await page.locator("[data-element='header-selector']").nth(1).click();
  await page.getByText("Add study", { exact: true }).click();
};

const openNewComponentDialog = async (page: Page) => {
  const firstComponentButton = page.getByRole("button", {
    name: "Create component",
  });
  if (await firstComponentButton.isVisible()) {
    await firstComponentButton.click();
    return;
  }

  await page.getByRole("button", { name: "Add component" }).click();
};

const chooseComponentType = async (page: Page, name: string) => {
  await openNewComponentDialog(page);
  await page.getByRole("radio", { name }).check();
  await page.getByRole("link", { name: "Create component" }).click();
};

test.describe("study authoring", () => {
  test("creates, schedules, and publishes a complete study", async ({
    researcherPage: page,
  }, testInfo) => {
    const suffix = `${Date.now()}-${testInfo.project.name}`;
    const studyTitle = `Authoring E2E ${suffix}`;
    const informationName = `Welcome ${suffix}`;
    const questionnaireName = `Wellbeing ${suffix}`;
    const healthDataName = `Vitals ${suffix}`;

    await expect(
      page.getByText("Schmiedmayer Lab", { exact: true }),
    ).toBeVisible();

    await openNewStudyDialog(page);
    await page.getByLabel("Study title").fill(studyTitle);
    await page.getByRole("button", { name: "Create study" }).click();
    await expect(page.getByText(studyTitle, { exact: true })).toBeVisible();

    await page.getByRole("link", { name: "Components", exact: true }).click();

    await chooseComponentType(page, "Information");
    await page.getByRole("textbox", { name: /^Name\b/ }).fill(informationName);
    await page.getByLabel(/Title/).fill("Welcome to the study");
    await page.getByLabel(/Lede/).fill("What to expect");
    await page
      .locator(".ProseMirror")
      .fill("Read this before getting started.");
    await page.getByRole("button", { name: "Save" }).click();
    await expect(
      page.getByRole("link", { name: informationName, exact: true }),
    ).toBeVisible();

    await page
      .getByRole("link", { name: informationName, exact: true })
      .click();
    await page.getByRole("button", { name: "Add schedule" }).click();
    await page
      .getByRole("dialog")
      .getByRole("button", { name: "Add schedule" })
      .click();
    await expect(
      page.getByText("Schedule created", { exact: true }),
    ).toBeVisible();
    await page.getByRole("link", { name: "Back" }).click();

    await chooseComponentType(page, "Questionnaire");
    await page
      .getByRole("textbox", { name: /^Name\b/ })
      .fill(questionnaireName);
    await page
      .getByRole("textbox", { name: /^FHIR questionnaire JSON\b/ })
      .fill(questionnaire);
    await page.getByRole("button", { name: "Save" }).click();
    await expect(
      page.getByRole("link", { name: questionnaireName, exact: true }),
    ).toBeVisible();

    await chooseComponentType(page, "Health data");
    await page.getByRole("textbox", { name: /^Name\b/ }).fill(healthDataName);
    await page.getByRole("combobox").click();
    await page.getByRole("option", { name: "Heart Rate", exact: true }).click();
    await page.getByRole("button", { name: "Save" }).click();
    await expect(
      page.getByRole("link", { name: healthDataName, exact: true }),
    ).toBeVisible();

    const publishResponse = page.waitForResponse(
      (response) =>
        response.request().method() === "POST" &&
        /\/api\/v0\/studies\/[^/]+\/publish$/.test(response.url()),
    );
    await page.getByRole("button", { name: "Publish", exact: true }).click();
    await page.getByRole("button", { name: "Publish v1" }).click();
    expect((await publishResponse).ok()).toBe(true);
    await expect(page.getByText("Study published (v1)")).toBeVisible();

    await page.getByRole("button", { name: "Publish", exact: true }).click();
    await expect(page.getByText(/current: v1/)).toBeVisible();
    await expect(
      page.getByRole("button", { name: "Publish v2" }),
    ).toBeVisible();
  });
});
