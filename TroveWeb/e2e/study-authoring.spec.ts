//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import type { Page } from "@playwright/test";
import {
  zStudyDraftValidation,
  zStudyResponse,
  zStudyPatchInput,
} from "../src/lib/api/generated/zod.gen";
import { expect, openNewStudyDialog, test } from "./fixtures";

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
  const listedComponent = page.getByRole("table").getByRole("link");
  // The configuration overview has its own empty-state button, so first wait for the
  // components route, then until its list has loaded into the empty state or a list.
  await expect(page).toHaveURL(/\/configuration\/components\/?$/);
  await expect(firstComponentButton.or(listedComponent).first()).toBeVisible();
  if (await firstComponentButton.isVisible()) {
    await firstComponentButton.click();
  } else {
    await page.getByRole("button", { name: "Add component" }).click();
  }
  await expect(
    page.getByRole("dialog", { name: "Choose a component type" }),
  ).toBeVisible();
};

const chooseComponentType = async (page: Page, name: string) => {
  await openNewComponentDialog(page);
  await page.getByRole("radio", { name }).check();
  await page.getByRole("link", { name: "Create component" }).click();
};

const completeReadiness = async (page: Page) => {
  for (const [name, value] of Object.entries({
    Aims: "Measure daily activity",
    Population: "Adults",
    "Procedures and collected data": "Answer a daily survey",
    "Participant burden": "Five minutes a day",
    "Data retention": "One year",
    Withdrawal: "Contact the coordinator",
  }))
    await page.getByRole("textbox", { name, exact: true }).fill(value);
  await page.getByRole("button", { name: "Add contact" }).press("Enter");
  const contact = page.getByRole("group", { name: "Contact 1", exact: true });
  await expect(contact.getByLabel("Name", { exact: true })).toBeFocused();
  await contact.getByLabel("Name", { exact: true }).fill("Study coordinator");
  await contact.getByLabel("Role", { exact: true }).fill("Coordinator");
  await contact
    .getByLabel("Email", { exact: true })
    .fill("coordinator@example.org");
  const saved = page.waitForResponse(
    (response) =>
      response.request().method() === "PATCH" &&
      /\/studies\/[^/]+$/.test(response.url()),
  );
  await page.getByRole("button", { name: "Save", exact: true }).click();
  expect((await saved).status()).toBe(200);
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
  const report = zStudyDraftValidation.parse(await validated.json());
  expect(report.status).toBe("valid");
  const candidate = report.candidate;
  if (!candidate) throw new Error("A valid draft must return a candidate");
  await expect(
    page.getByRole("heading", { name: "Review publication candidate" }),
  ).toBeVisible();
  await expect(page.getByText(candidate.id, { exact: true })).toBeVisible();
  await expect(
    page.getByText(candidate.bundleSha256, { exact: true }),
  ).toBeVisible();
  expect((await validated.request().allHeaders())["if-match"]).toBe(
    `"${report.draftRevision}"`,
  );
  return { ...candidate, draftRevision: report.draftRevision };
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

  test("keeps translated facts separate and contacts shared", async ({
    researcherPage: page,
  }) => {
    await openNewStudyDialog(page);
    await page.getByLabel("Study title").fill(`Readiness E2E ${Date.now()}`);
    await page.getByRole("button", { name: "Create study" }).click();
    await page.getByTestId("edit-general").click();
    await completeReadiness(page);
    await page.getByLabel("Add a language").fill("de");
    await page.getByRole("button", { name: "Add", exact: true }).click();
    const aims = page.getByRole("textbox", { name: "Aims", exact: true });
    await expect(aims).toHaveValue("");
    await expect(page.getByLabel("Email", { exact: true })).toHaveValue(
      "coordinator@example.org",
    );
    await page
      .getByRole("textbox", { name: /^Title\b/ })
      .fill("Aktivitätsstudie");
    await aims.fill("Aktivität beschreiben");
    const saved = page.waitForResponse(
      (response) =>
        response.request().method() === "PATCH" &&
        /\/studies\/[^/]+$/.test(response.url()),
    );
    const studyPatch = "**/studies/*";
    let release!: () => void;
    const hold = new Promise<void>((resolve) => {
      release = resolve;
    });
    await page.route(studyPatch, async (route) => {
      if (route.request().method() === "PATCH") await hold;
      await route.continue();
    });
    try {
      await aims.press("Control+Enter");
      await expect(aims).toBeDisabled();
      await expect(page.getByLabel("Email", { exact: true })).toBeDisabled();
      await expect(
        page.getByRole("button", { name: "Add contact" }),
      ).toBeDisabled();
      await expect(
        page.getByRole("button", { name: "Remove contact 1" }),
      ).toBeDisabled();
    } finally {
      release();
    }
    const response = await saved;
    expect(response.status()).toBe(200);
    await page.unroute(studyPatch);
    const translated = zStudyResponse.parse(await response.json());
    expect(translated.readinessFacts).toMatchObject({
      content: {
        en: { aims: "Measure daily activity" },
        de: { aims: "Aktivität beschreiben" },
      },
      contacts: [{ email: "coordinator@example.org" }],
    });
    await expect(aims).toBeEnabled();
    await page.getByRole("button", { name: "Remove language" }).click();
    const removal = page.waitForResponse(
      (result) =>
        result.url() === response.url() &&
        result.request().method() === "PATCH",
    );
    await page
      .getByRole("dialog")
      .getByRole("button", { name: "Delete language" })
      .click();
    const removed = await removal;
    expect(removed.status()).toBe(200);
    expect(await removed.request().headerValue("if-match")).toBe(
      `"${translated.draftRevision}"`,
    );
    const expected = {
      details: {
        ...translated.details,
        content: { en: translated.details.content.en },
      },
      readinessFacts: {
        ...translated.readinessFacts,
        content: { en: translated.readinessFacts.content.en },
      },
    };
    expect(removed.request().postDataJSON()).toEqual(expected);
    const persisted = zStudyResponse.parse(await removed.json());
    expect(persisted.details).toEqual(expected.details);
    expect(persisted.readinessFacts).toEqual(expected.readinessFacts);
    await page.reload();
    await page.getByLabel("Add a language").fill("de");
    await page.getByRole("button", { name: "Add", exact: true }).click();
    await expect(aims).toHaveValue("");
    await expect(page.getByLabel("Email", { exact: true })).toHaveValue(
      "coordinator@example.org",
    );
  });

  test("keeps the implicit editing language and revision when the source changes", async ({
    researcherPage: page,
  }) => {
    await openNewStudyDialog(page);
    await page.getByLabel("Study title").fill("Source language refetch");
    const created = page.waitForResponse(
      (response) =>
        response.request().method() === "POST" &&
        /\/groups\/[^/]+\/studies$/.test(response.url()),
    );
    await page.getByRole("button", { name: "Create study" }).click();
    const original = zStudyResponse.parse(await (await created).json());
    await page.getByTestId("edit-general").click();
    const aims = page.getByRole("textbox", { name: "Aims", exact: true });
    await aims.fill("Unsaved source wording");
    const other = await page.context().newPage();
    try {
      await other.goto(page.url());
      await other.getByLabel("Add a language").fill("de");
      await other.getByRole("button", { name: "Add", exact: true }).click();
      const title = other.getByRole("textbox", { name: /^Title\b/ });
      await expect(title).toHaveValue("");
      await title.fill("Deutscher Titel");
      const studyPath = "**/studies/" + original.id;
      const patch = (tab: Page) =>
        tab.waitForResponse(
          (response) =>
            response.url().endsWith("/studies/" + original.id) &&
            response.request().method() === "PATCH",
        );
      const saved = patch(other);
      await other.getByRole("button", { name: "Save", exact: true }).click();
      expect((await saved).status()).toBe(200);
      const switched = patch(other);
      await other.getByRole("button", { name: "Make source language" }).click();
      expect((await switched).status()).toBe(200);
      const refetched = page.waitForResponse(studyPath);
      await page.bringToFront();
      await page.evaluate(() =>
        window.dispatchEvent(new Event("visibilitychange")),
      );
      expect(
        zStudyResponse.parse(await (await refetched).json()).details
          .sourceLanguage,
      ).toBe("de");
      await expect(aims).toHaveAttribute(
        "lang",
        original.details.sourceLanguage,
      );
      await expect(aims).toHaveValue("Unsaved source wording");
      const stale = patch(page);
      await page.getByRole("button", { name: "Save", exact: true }).click();
      const rejected = await stale;
      expect(rejected.status()).toBe(412);
      expect(await rejected.request().headerValue("if-match")).toBe(
        `"${original.draftRevision}"`,
      );
      const body = zStudyPatchInput.parse(rejected.request().postDataJSON());
      expect(Object.keys(body.readinessFacts?.content ?? {})).toEqual([
        original.details.sourceLanguage,
      ]);
      expect(
        body.readinessFacts?.content[original.details.sourceLanguage]?.aims,
      ).toBe("Unsaved source wording");
    } finally {
      await other.close();
    }
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
    await completeReadiness(page);
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

    await page.getByTestId("edit-general").click();
    await completeReadiness(page);
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

    await page
      .getByRole("link", { name: questionnaireName, exact: true })
      .click();
    await page
      .getByRole("button", { name: "Approve en-US", exact: true })
      .press("Enter");
    const revoke = page.getByRole("button", {
      name: "Revoke approval for en-US",
    });
    await expect(revoke).toBeEnabled();
    await revoke.press("Enter");
    const approve = page.getByRole("button", {
      name: "Approve en-US",
      exact: true,
    });
    await expect(approve).toBeEnabled();
    await approve.press("Enter");
    await expect(revoke).toBeEnabled();
    await page.getByRole("link", { name: "Back", exact: true }).click();
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

  test("lists the blockers of a draft that cannot be published and focuses them", async ({
    researcherPage: page,
  }, testInfo) => {
    const suffix = `${Date.now()}-${testInfo.project.name}`;
    const studyTitle = `Blocked E2E ${suffix}`;
    const questionnaireName = `Draft questionnaire ${suffix}`;

    await openNewStudyDialog(page);
    await page.getByLabel("Study title").fill(studyTitle);
    await page.getByRole("button", { name: "Create study" }).click();
    await expect(
      page.getByRole("button", { name: studyTitle, exact: true }),
    ).toBeVisible();
    await page.getByRole("link", { name: "Components", exact: true }).click();

    // Only an active Questionnaire can be published; a draft one is a blocker
    // whether or not the FHIR validator is reachable.
    await chooseComponentType(page, "Questionnaire");
    await page
      .getByRole("textbox", { name: /^Name\b/ })
      .fill(questionnaireName);
    await page
      .getByRole("textbox", { name: /^FHIR questionnaire JSON\b/ })
      .fill(questionnaire.replace('"status":"active"', '"status":"draft"'));
    await page.getByRole("button", { name: "Save" }).click();
    await expect(
      page.getByRole("link", { name: questionnaireName, exact: true }),
    ).toBeVisible();

    await page.getByRole("button", { name: "Publish", exact: true }).click();
    const validationResponse = page.waitForResponse(
      (response) =>
        response.request().method() === "POST" &&
        /\/api\/v0\/studies\/[^/]+\/draft\/validations$/.test(response.url()),
    );
    await page
      .getByRole("button", { name: "Validate draft", exact: true })
      .click();
    const validated = await validationResponse;
    expect(validated.status()).toBe(200);
    const report = zStudyDraftValidation.parse(await validated.json());
    expect(report.candidate).toBeUndefined();
    expect(report.blockers.map((blocker) => blocker.rule)).toContain(
      "status-active",
    );

    const blockers = page.getByRole("heading", { name: "Blockers" });
    await expect(blockers).toHaveCount(1);
    await expect(blockers).toBeFocused();
    await expect(
      page.getByText("Only an active Questionnaire can be published."),
    ).toBeVisible();
    await expect(page.getByRole("button", { name: /^Publish v/ })).toHaveCount(
      0,
    );
    await page.getByRole("button", { name: /^Edit aims \(/ }).press("Enter");
    await expect(
      page.getByRole("textbox", { name: "Aims", exact: true }),
    ).toBeFocused();
  });
});
