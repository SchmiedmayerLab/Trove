//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import type { Page } from "@playwright/test";
import { expect, openNewStudyDialog, test } from "./fixtures";
import { zStudyDraftValidation } from "../src/lib/api/generated/zod.gen";

const questionnaire = JSON.stringify({
  resourceType: "Questionnaire",
  id: "wellbeing-questionnaire",
  language: "en-US",
  meta: {
    profile: [
      "https://grovealliance.org/fhir/questionnaire/StructureDefinition/grove-questionnaire",
    ],
  },
  extension: [
    {
      url: "http://hl7.org/fhir/StructureDefinition/artifact-versionAlgorithm",
      valueCoding: {
        system: "http://hl7.org/fhir/version-algorithm",
        code: "semver",
      },
    },
  ],
  url: "https://example.org/fhir/Questionnaire/wellbeing",
  version: "1.0.0",
  title: "Daily wellbeing",
  status: "active",
  subjectType: ["Patient"],
  item: [
    {
      linkId: "wellbeing",
      text: "How are you feeling today?",
      type: "string",
    },
  ],
});

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

const reviewPublicationCandidate = async (page: Page) => {
  await page.getByRole("button", { name: "Publish", exact: true }).click();
  await expect(page.getByRole("button", { name: "Publish v1" })).toHaveCount(0);
  const validationResponse = page.waitForResponse(
    (response) =>
      response.request().method() === "POST" &&
      /\/api\/v0\/studies\/[^/]+\/draft\/validations$/.test(response.url()),
  );
  await page
    .getByRole("button", { name: "Validate draft", exact: true })
    .click();
  const validated = await validationResponse;
  expect(validated.status()).toBe(201);
  const candidate = zStudyDraftValidation.parse(await validated.json());
  await expect(
    page.getByRole("heading", { name: "Review publication candidate" }),
  ).toBeVisible();
  await expect(page.getByText(candidate.id, { exact: true })).toBeVisible();
  await expect(
    page.getByText(candidate.bundleSha256, { exact: true }),
  ).toBeVisible();
  expect((await validated.request().allHeaders())["if-match"]).toBe(
    `"${candidate.draftRevision}"`,
  );
  return candidate;
};

test.describe("study authoring", () => {
  test("persists enrollment settings together with participation criteria", async ({
    researcherPage: page,
  }) => {
    const title = `Enrollment E2E ${Date.now()}`;
    await openNewStudyDialog(page);
    await page.getByLabel("Study title").fill(title);
    await page.getByRole("button", { name: "Create study" }).click();
    await expect(page).toHaveURL(/\/configuration$/);
    await page.getByTestId("edit-enrollment").click();
    const addCriterion = page.getByRole("button", {
      name: "Add participation criterion",
    });
    if (await addCriterion.isVisible()) await addCriterion.click();
    await page.getByRole("button", { name: "Add rule", exact: true }).click();
    await page.getByRole("spinbutton", { name: "Minimum age" }).fill("21");
    await page
      .getByRole("radio", { name: /^Requires invitation code/ })
      .check();
    await page.getByRole("radio", { name: /^Unlisted/ }).check();
    const saved = page.waitForResponse(
      (response) =>
        response.request().method() === "PATCH" &&
        /\/studies\/[^/]+$/.test(response.url()),
    );
    await page.getByRole("button", { name: "Save", exact: true }).click();
    expect((await saved).status()).toBe(200);
    await page.reload();
    await expect(
      page.getByRole("spinbutton", { name: "Minimum age" }),
    ).toHaveValue("21");
    await expect(
      page.getByRole("radio", { name: /^Requires invitation code/ }),
    ).toBeChecked();
    await expect(page.getByRole("radio", { name: /^Unlisted/ })).toBeChecked();
  });

  test("preserves unsaved work and rejects a stale draft from another tab", async ({
    researcherPage: page,
  }, testInfo) => {
    // This covers two-tab editing, explicit reload, validation and stale publication.
    test.slow();
    const original = `Revision E2E ${Date.now()}-${testInfo.project.name}`;
    await openNewStudyDialog(page);
    await page.getByLabel("Study title").fill(original);
    await page.getByRole("button", { name: "Create study" }).click();
    await expect(page).toHaveURL(/\/configuration$/);
    await expect(
      page.getByRole("button", { name: original, exact: true }),
    ).toBeVisible();
    await page
      .getByRole("link", { name: "Configuration", exact: true })
      .click();
    await page.getByTestId("edit-general").click();
    const title = page.getByRole("textbox", { name: /^Title\b/ });
    await expect(title).toHaveValue(original);
    const other = await page.context().newPage();
    try {
      await other.goto(page.url());
      const otherTitle = other.getByRole("textbox", { name: /^Title\b/ });
      await expect(otherTitle).toHaveValue(original);
      await title.fill(`${original} unsaved`);
      await otherTitle.fill(`${original} newer`);
      const saved = other.waitForResponse(
        (response) =>
          response.request().method() === "PATCH" &&
          /\/studies\/[^/]+$/.test(response.url()),
      );
      await other.getByRole("button", { name: "Save", exact: true }).click();
      expect((await saved).status()).toBe(200);
      await page.bringToFront();
      await expect(title).toHaveValue(`${original} unsaved`);
      const rejected = page.waitForResponse(
        (response) =>
          response.request().method() === "PATCH" &&
          /\/studies\/[^/]+$/.test(response.url()),
      );
      await page.getByRole("button", { name: "Save", exact: true }).click();
      expect((await rejected).status()).toBe(412);
      await expect(
        page.getByText("The study draft has changed", { exact: true }),
      ).toBeVisible();
      await expect(title).toHaveValue(`${original} unsaved`);
      page.once("dialog", (dialog) => {
        void dialog.accept();
      });
      await Promise.all([
        page.waitForEvent("domcontentloaded"),
        page.getByRole("button", { name: "Reload draft", exact: true }).click(),
      ]);
      await expect(title).toHaveValue(`${original} newer`);

      const candidate = await reviewPublicationCandidate(page);
      await otherTitle.fill(`${original} changed after validation`);
      const changed = other.waitForResponse(
        (response) =>
          response.request().method() === "PATCH" &&
          /\/studies\/[^/]+$/.test(response.url()),
      );
      await other.getByRole("button", { name: "Save", exact: true }).click();
      expect((await changed).status()).toBe(200);
      await page.bringToFront();
      await expect(page.getByText(candidate.id, { exact: true })).toBeVisible();
      const refused = page.waitForResponse(
        (response) =>
          response.request().method() === "POST" &&
          /\/studies\/[^/]+\/publish$/.test(response.url()),
      );
      await page
        .getByRole("button", { name: "Publish v1", exact: true })
        .click();
      const stalePublication = await refused;
      expect(stalePublication.status()).toBe(412);
      expect(stalePublication.request().postDataJSON()).toEqual({
        validationId: candidate.id,
      });
      expect((await stalePublication.request().allHeaders())["if-match"]).toBe(
        `"${candidate.draftRevision}"`,
      );
      await expect(
        page.getByRole("button", { name: "Reload and review", exact: true }),
      ).toBeVisible();
      await expect(
        page.getByRole("button", { name: "Publish v1", exact: true }),
      ).toHaveCount(0);
    } finally {
      await other.close();
    }
  });

  test("creates, schedules, and publishes a complete study", async ({
    researcherPage: page,
  }, testInfo) => {
    // This journey includes login, three component forms, scheduling and publication.
    // Allow the full workflow its own budget without relaxing individual assertions.
    test.slow();

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
    await expect(
      page.getByRole("button", { name: studyTitle, exact: true }),
    ).toBeVisible();

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

    const candidate = await reviewPublicationCandidate(page);

    const publishResponse = page.waitForResponse(
      (response) =>
        response.request().method() === "POST" &&
        /\/api\/v0\/studies\/[^/]+\/publish$/.test(response.url()),
    );
    await page.getByRole("button", { name: "Publish v1" }).click();
    const accepted = await publishResponse;
    expect(accepted.status()).toBe(201);
    expect(accepted.request().postDataJSON()).toEqual({
      validationId: candidate.id,
    });
    expect((await accepted.request().allHeaders())["if-match"]).toBe(
      `"${candidate.draftRevision}"`,
    );
    await expect(page.getByText("Study published (v1)")).toBeVisible();

    await page.getByRole("button", { name: "Publish", exact: true }).click();
    await expect(
      page.getByText(/Current published revision: v1/),
    ).toBeVisible();
    await expect(
      page.getByRole("button", { name: "Validate draft", exact: true }),
    ).toBeVisible();
    await expect(page.getByRole("button", { name: "Publish v2" })).toHaveCount(
      0,
    );
  });
});
