// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import type { Page } from "@playwright/test";
import { zStudyResponse } from "../src/lib/api/generated/zod.gen";
import { heartRateProfile } from "../src/routes/~(dashboard)/~$group/~$study/~configuration/lib/collectionForm";
import { expect, openNewStudyDialog, test } from "./fixtures";

const openCollection = async (page: Page) => {
  await openNewStudyDialog(page);
  await page.getByLabel("Study title").fill(`Collection E2E ${Date.now()}`);
  const creation = page.waitForResponse(
    (response) =>
      response.request().method() === "POST" &&
      /\/groups\/[^/]+\/studies$/.test(response.url()),
  );
  await page.getByRole("button", { name: "Create study" }).click();
  const created = await creation;
  expect(created.status()).toBe(201);
  const study = zStudyResponse.parse(await created.json());
  await expect(page).toHaveURL(/\/configuration$/);
  await page.getByTestId("edit-collection").click();
  await expect(
    page.getByRole("link", { name: "Health collection", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole("radio", { name: "None", exact: true }),
  ).toBeChecked();
  return study;
};

const saveCollection = async (
  page: Page,
  revision: string,
  expectedStatus = 200,
) => {
  const response = page.waitForResponse(
    (response) =>
      response.request().method() === "PATCH" &&
      /\/studies\/[^/]+$/.test(response.url()),
  );
  await page.getByRole("button", { name: "Save", exact: true }).click();
  const saved = await response;
  expect(saved.status()).toBe(expectedStatus);
  expect((await saved.request().allHeaders())["if-match"]).toBe(
    `"${revision}"`,
  );
  return saved;
};

test("authors, reloads and preserves exact historical collection windows", async ({
  researcherPage: page,
}, testInfo) => {
  test.slow();
  const initial = await openCollection(page);
  await page.getByRole("radio", { name: "Heart rate", exact: true }).check();
  await page
    .getByRole("radio", { name: "Calendar lookback", exact: true })
    .check();
  await expect(
    page.getByRole("spinbutton", { name: "Months", exact: true }),
  ).toHaveValue("6");
  await page
    .getByLabel("Calendar time zone", { exact: true })
    .fill("America/Los_Angeles");
  const saved = zStudyResponse.parse(
    await (await saveCollection(page, initial.draftRevision)).json(),
  );
  expect(saved.collectionRequirements).toEqual([
    {
      profile: heartRateProfile,
      sourceKind: "participant-app",
      measurementWindow: {
        calendar: "gregorian",
        timeZone: "America/Los_Angeles",
        start: { type: "last", components: { month: 6 } },
      },
    },
  ]);
  await page.reload();
  await expect(
    page.getByRole("radio", { name: "Calendar lookback", exact: true }),
  ).toBeChecked();
  await expect(
    page.getByRole("spinbutton", { name: "Months", exact: true }),
  ).toHaveValue("6");
  await expect(
    page.getByLabel("Calendar time zone", { exact: true }),
  ).toHaveValue("America/Los_Angeles");
  await expect(
    page.getByRole("status").filter({ hasText: "Collection scope" }),
  ).toContainText("6 months from each participant's acceptance");
  await page.screenshot({
    path: testInfo.outputPath("collection-lookback.png"),
    fullPage: true,
  });

  let patchCount = 0;
  page.on("request", (request) => {
    if (request.method() === "PATCH") patchCount++;
  });
  await page.getByRole("spinbutton", { name: "Months", exact: true }).fill("0");
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await expect(
    page.getByText("Enter a lookback greater than zero.", { exact: true }),
  ).toBeVisible();
  expect(patchCount).toBe(0);

  await page
    .getByRole("radio", { name: "Specific date and time", exact: true })
    .check();
  const start = "2026-01-01T00:00:00.123456Z";
  const end = "2027-01-01T00:00:00.234567Z";
  await page.getByLabel("Start (UTC, inclusive)", { exact: true }).fill(start);
  await page
    .getByLabel("End (UTC, exclusive, optional)", { exact: true })
    .fill(end);
  const fixed = zStudyResponse.parse(
    await (await saveCollection(page, saved.draftRevision)).json(),
  );
  await page.reload();
  await expect(
    page.getByLabel("Start (UTC, inclusive)", { exact: true }),
  ).toHaveValue(start);
  await expect(
    page.getByLabel("End (UTC, exclusive, optional)", { exact: true }),
  ).toHaveValue(end);
  await page.getByLabel("Calendar time zone", { exact: true }).fill("UTC");
  const precise = zStudyResponse.parse(
    await (await saveCollection(page, fixed.draftRevision)).json(),
  );
  expect(precise.collectionRequirements[0].measurementWindow).toEqual({
    calendar: "gregorian",
    timeZone: "UTC",
    start: { type: "absolute", date: start },
    end,
  });

  await page
    .getByRole("radio", { name: "All available history", exact: true })
    .check();
  const all = zStudyResponse.parse(
    await (await saveCollection(page, precise.draftRevision)).json(),
  );
  expect(all.collectionRequirements[0].measurementWindow?.start).toEqual({
    type: "oldestSample",
  });
  expect(all.collectionRequirements[0].measurementWindow?.end).toBe(end);
  await page
    .getByRole("radio", { name: "From participant acceptance", exact: true })
    .check();
  const forward = zStudyResponse.parse(
    await (await saveCollection(page, all.draftRevision)).json(),
  );
  expect(
    forward.collectionRequirements[0].measurementWindow?.start,
  ).toBeUndefined();
  expect(forward.collectionRequirements[0].measurementWindow?.end).toBe(end);
  await page.getByRole("radio", { name: "None", exact: true }).check();
  const none = zStudyResponse.parse(
    await (await saveCollection(page, forward.draftRevision)).json(),
  );
  expect(none.collectionRequirements).toEqual([]);
});

test("keeps an unsaved collection scope and refuses a stale revision", async ({
  researcherPage: page,
}) => {
  test.slow();
  const initial = await openCollection(page);
  const other = await page.context().newPage();
  try {
    await other.goto(page.url());
    await expect(
      other.getByRole("radio", { name: "None", exact: true }),
    ).toBeChecked();
    await page.getByRole("radio", { name: "Heart rate", exact: true }).check();
    await page
      .getByRole("radio", { name: "Calendar lookback", exact: true })
      .check();
    await other.getByRole("radio", { name: "Heart rate", exact: true }).check();
    await other
      .getByRole("radio", { name: "All available history", exact: true })
      .check();
    await saveCollection(other, initial.draftRevision);
    await page.bringToFront();
    await expect(
      page.getByRole("spinbutton", { name: "Months", exact: true }),
    ).toHaveValue("6");
    await saveCollection(page, initial.draftRevision, 412);
    await expect(
      page.getByText("The study draft has changed", { exact: true }),
    ).toBeVisible();
    await expect(
      page.getByRole("spinbutton", { name: "Months", exact: true }),
    ).toHaveValue("6");
    await other.reload();
    await expect(
      other.getByRole("radio", { name: "All available history", exact: true }),
    ).toBeChecked();
  } finally {
    await other.close();
  }
});
