// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import type { Page, Route } from "@playwright/test";
import { zStudyResponse } from "../src/lib/api/generated/zod.gen";
import {
  bodyWeightProfile,
  heartRateProfile,
} from "../src/routes/~(dashboard)/~$group/~$study/~configuration/lib/collectionForm";
import { expect, openNewStudyDialog, test } from "./fixtures";

const heartRate = (page: Page) =>
  page.getByRole("checkbox", { name: "Collect heart rate", exact: true });

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
  await expect(heartRate(page)).not.toBeChecked();
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
  await heartRate(page).check();
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
      requirement: "required",
      sourceKind: "participant-app",
      sourceTypeIdentifier: "HKQuantityTypeIdentifierHeartRate",
      timeBasis: "measurement-time",
      includeWorkoutRoutes: false,
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
  const scope = page
    .getByRole("status")
    .filter({ hasText: "Collection scope" });
  await expect(scope).toContainText(
    "6 months from each participant's acceptance",
  );
  // The complete measurement catalog makes the page taller than a browser can capture in one image.
  await scope.screenshot({
    path: testInfo.outputPath("collection-lookback.png"),
  });

  let patchCount = 0;
  page.on("request", (request) => {
    if (request.method() === "PATCH") patchCount++;
  });
  await page.getByRole("spinbutton", { name: "Months", exact: true }).fill("0");
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await expect(
    page.getByText("Enter a calendar period greater than zero.", {
      exact: true,
    }),
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
  await heartRate(page).uncheck();
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
    await expect(heartRate(other)).not.toBeChecked();
    await heartRate(page).check();
    await page
      .getByRole("radio", { name: "Calendar lookback", exact: true })
      .check();
    await heartRate(other).check();
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

test("blocks button and keyboard saves after a provider catalog refetch fails", async ({
  researcherPage: page,
}) => {
  const initial = await openCollection(page);
  await heartRate(page).check();
  const catalog = "**/studies/*/collection-provider-capabilities";
  await page.route(catalog, (route) =>
    route.fulfill({ status: 503, body: "{}" }),
  );
  const patches: string[] = [];
  page.on("request", (request) => {
    if (
      request.method() === "PATCH" &&
      request.url().endsWith(`/studies/${initial.id}`)
    )
      patches.push(request.url());
  });
  const refetch = () =>
    page.evaluate(() => window.dispatchEvent(new Event("visibilitychange")));
  await refetch();
  await expect(
    page
      .getByRole("alert")
      .filter({ hasText: "Collection settings could not be loaded" }),
  ).toBeVisible({ timeout: 20_000 });
  const save = page.getByRole("button", { name: "Save", exact: true });
  await expect(save).toBeDisabled();
  await save.evaluate((button: HTMLButtonElement) => button.click());
  await page.keyboard.press("Meta+Enter");
  await page.unroute(catalog);
  await refetch();
  await expect(heartRate(page)).toBeChecked();
  expect(patches).toHaveLength(0);
  await saveCollection(page, initial.draftRevision);
  expect(patches).toHaveLength(1);
});

test("repairs a withdrawn provider route without changing the other saved scope", async ({
  researcherPage: page,
}) => {
  test.slow();
  const initial = await openCollection(page);
  const other = {
    profile: heartRateProfile,
    sourceKind: "participant-app",
    sourceTypeIdentifier: "HKQuantityTypeIdentifierHeartRate",
    includeWorkoutRoutes: false,
    requirement: "required",
    timeBasis: "measurement-time",
    measurementWindow: {
      calendar: "gregorian",
      timeZone: "UTC",
      start: { type: "last", components: { month: 6 } },
    },
  };
  const unavailable = {
    profile: bodyWeightProfile,
    sourceKind: "server-worker",
    providerRegistrationId: "10000000-0000-4000-8000-000000000099",
    sourceTypeIdentifier: "getmeas:1",
    includeWorkoutRoutes: false,
    requirement: "required",
    measurementWindow: {
      calendar: "gregorian",
      timeZone: "UTC",
      start: { type: "oldestSample" },
    },
  };
  const removed = {
    ...unavailable,
    providerRegistrationId: "10000000-0000-4000-8000-000000000098",
  };
  // Seed the draft through its normal versioned PATCH, with a registration absent from the live catalog.
  const seed = async (route: Route) => {
    if (route.request().method() !== "PATCH") return route.fallback();
    await route.continue({
      postData: JSON.stringify({
        collectionRequirements: [unavailable, other, removed],
      }),
    });
  };
  await page.route(`**/studies/${initial.id}`, seed);
  await heartRate(page).check();
  const seeded = zStudyResponse.parse(
    await (await saveCollection(page, initial.draftRevision)).json(),
  );
  await page.unroute(`**/studies/${initial.id}`, seed);
  await page.reload();
  const rows = page.getByRole("group", {
    name: "Unavailable collection route",
  });
  const row = rows.filter({ hasText: unavailable.providerRegistrationId });
  await rows
    .filter({ hasText: removed.providerRegistrationId })
    .getByRole("button", { name: "Remove unavailable route" })
    .click();
  await expect(row).toContainText(unavailable.providerRegistrationId);
  await row.getByLabel("Publication requirement").selectOption("optional");
  const optional = zStudyResponse.parse(
    await (await saveCollection(page, seeded.draftRevision)).json(),
  );
  expect(optional.collectionRequirements).toEqual([
    { ...unavailable, requirement: "optional" },
    other,
  ]);
  await page.reload();
  await expect(row.getByLabel("Publication requirement")).toHaveValue(
    "optional",
  );
  const editing = await page.context().newPage();
  try {
    await editing.goto(page.url());
    const level = editing
      .getByRole("group", { name: "Unavailable collection route" })
      .getByLabel("Publication requirement");
    await level.selectOption("required");
    await row
      .getByLabel("Replace with an available route")
      .selectOption({ index: 1 });
    const replaced = zStudyResponse.parse(
      await (await saveCollection(page, optional.draftRevision)).json(),
    );
    expect(replaced.collectionRequirements).toHaveLength(2);
    expect(replaced.collectionRequirements[0]).toMatchObject({
      profile: bodyWeightProfile,
      sourceKind: "participant-app",
      requirement: "optional",
      measurementWindow: unavailable.measurementWindow,
    });
    expect(replaced.collectionRequirements[1]).toEqual(other);
    await expect(row).toHaveCount(0);

    const refetched = editing.waitForResponse(`**/studies/${initial.id}`);
    await editing.bringToFront();
    await editing.evaluate(() =>
      window.dispatchEvent(new Event("visibilitychange")),
    );
    expect(
      zStudyResponse.parse(await (await refetched).json()).draftRevision,
    ).toBe(replaced.draftRevision);
    await expect(level).toHaveValue("required");
    const stale = await saveCollection(editing, optional.draftRevision, 412);
    expect(stale.request().postDataJSON()).toMatchObject({
      collectionRequirements: [unavailable, other],
    });
  } finally {
    await editing.close();
  }
});
