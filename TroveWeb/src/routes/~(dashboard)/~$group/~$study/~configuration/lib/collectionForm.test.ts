// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { describe, expect, it } from "vitest";
import type { CollectionMeasurementWindow } from "@/lib/api/generated/types.gen";
import {
  canEditCollection,
  collectionFormSchema,
  collectionSummary,
  newHeartRateRequirement,
} from "./collectionForm";

const requirement = newHeartRateRequirement();
const parseWindow = (measurementWindow: CollectionMeasurementWindow) =>
  collectionFormSchema.safeParse({
    collectionRequirements: [{ ...requirement, measurementWindow }],
  });

describe("collection authoring", () => {
  it("keeps omitted history consent-forward and does not insert defaults", () => {
    expect(
      collectionFormSchema.parse({ collectionRequirements: [requirement] }),
    ).toEqual({ collectionRequirements: [requirement] });
    expect(collectionFormSchema.parse({ collectionRequirements: [] })).toEqual({
      collectionRequirements: [],
    });
    expect(collectionSummary([requirement])).toContain(
      "from each participant's acceptance",
    );
  });

  it.each<CollectionMeasurementWindow>([
    { calendar: "gregorian", timeZone: "UTC" },
    {
      calendar: "gregorian",
      timeZone: "America/Los_Angeles",
      start: { type: "last", components: { month: 6 } },
    },
    {
      calendar: "gregorian",
      timeZone: "Europe/Berlin",
      start: { type: "last", components: { year: 1, month: 2, day: 0 } },
    },
    {
      calendar: "gregorian",
      timeZone: "UTC",
      start: { type: "oldestSample" },
      end: "2027-01-01T00:00:00.123456Z",
    },
    {
      calendar: "gregorian",
      timeZone: "UTC",
      start: { type: "absolute", date: "2026-01-01T00:00:00.123455Z" },
      end: "2026-01-01T00:00:00.123456Z",
    },
  ])(
    "round-trips every supported window without rebasing or rounding: %j",
    (measurementWindow) => {
      const value = {
        collectionRequirements: [{ ...requirement, measurementWindow }],
      };
      expect(collectionFormSchema.parse(value)).toEqual(value);
    },
  );

  it.each([
    {},
    { month: 0 },
    { month: -1 },
    { month: 0.5 },
    { month: 119989 },
    { year: 9999 },
    { day: 3652059 },
  ])(
    "refuses invalid calendar offsets instead of authorizing all history: %j",
    (components) => {
      expect(
        parseWindow({
          calendar: "gregorian",
          timeZone: "UTC",
          start: { type: "last", components },
        }).success,
      ).toBe(false);
    },
  );

  it.each(["", "Not/A_Zone", "+08:00", "America/Los_Angeles "])(
    "refuses invalid or implicit time zones: %s",
    (timeZone) => {
      expect(parseWindow({ calendar: "gregorian", timeZone }).success).toBe(
        false,
      );
    },
  );

  it.each([
    ["2026-01-01T00:00:00.123456Z", "2026-01-01T00:00:00.123455Z"],
    ["2026-01-01T00:00:00Z", "2026-01-01T00:00:00.000000Z"],
    ["2026-01-01T00:00:00.1Z", "2026-01-01T00:00:00.100000Z"],
    ["2026-02-30T00:00:00Z", "2026-03-01T00:00:00Z"],
  ])(
    "rejects backwards, empty and invalid ranges without millisecond rounding",
    (date, end) => {
      expect(
        parseWindow({
          calendar: "gregorian",
          timeZone: "UTC",
          start: { type: "absolute", date },
          end,
        }).success,
      ).toBe(false);
    },
  );

  it("does not coerce or discard unsupported settings", () => {
    for (const collectionRequirements of [
      [{ ...requirement, profile: "https://example.org/unsupported" }],
      [requirement, requirement],
      [{ ...requirement, sourceKind: "server-connector" }],
      [{ ...requirement, futureSetting: true }],
      [
        {
          ...requirement,
          measurementWindow: {
            calendar: "gregorian",
            timeZone: "UTC",
            futureSetting: true,
          },
        },
      ],
      [
        {
          ...requirement,
          measurementWindow: {
            calendar: "gregorian",
            timeZone: "UTC",
            start: { type: "last", components: { month: 6, hour: 1 } },
          },
        },
      ],
    ]) {
      const original = structuredClone(collectionRequirements);
      expect(canEditCollection(collectionRequirements)).toBe(false);
      expect(
        collectionFormSchema.safeParse({ collectionRequirements }).success,
      ).toBe(false);
      expect(collectionRequirements).toEqual(original);
    }
  });

  it("explains the acceptance anchor and exclusive bound without inventing dates", () => {
    const summary = collectionSummary([
      {
        ...requirement,
        measurementWindow: {
          calendar: "gregorian",
          timeZone: "America/Los_Angeles",
          start: { type: "last", components: { month: 6 } },
          end: "2027-01-01T00:00:00.123456Z",
        },
      },
    ]);
    expect(summary).toContain("6 months from each participant's acceptance");
    expect(summary).toContain("Gregorian calendar, America/Los_Angeles");
    expect(summary).toContain("Before 2027-01-01T00:00:00.123456Z (exclusive)");
  });
});
