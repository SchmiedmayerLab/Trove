// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { z } from "zod";
import type { CollectionRequirement } from "@/lib/api/generated/types.gen";
import {
  zAbsoluteStartDate,
  zCollectionMeasurementWindow,
  zCollectionRequirement,
  zDateComponents,
  zOldestSampleStartDate,
  zRelativeStartDate,
} from "@/lib/api/generated/zod.gen";

export const heartRateProfile =
  "https://grovealliance.org/fhir/mobile/StructureDefinition/grove-mobile-heart-rate";

const date = zAbsoluteStartDate.shape.date.refine(
  (value) =>
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$/.test(value) &&
    !value.startsWith("0000"),
  "Enter a complete UTC date and time, with at most six fractional second digits.",
);

// Compare at the API's microsecond precision without rounding through JavaScript Date.
const dateKey = (value: string) => {
  const [seconds, fraction = ""] = value.slice(0, -1).split(".");
  return `${seconds}.${fraction.padEnd(6, "0")}`;
};

const components = zDateComponents
  .extend({
    year: z.number().int().min(0).max(9998).optional(),
    month: z.number().int().min(0).max(119988).optional(),
    day: z.number().int().min(0).max(3652058).optional(),
  })
  .strict()
  .refine(
    (value) =>
      [value.year, value.month, value.day].some((part) => (part ?? 0) > 0),
    "Enter a lookback greater than zero.",
  );

const measurementWindow = zCollectionMeasurementWindow
  .extend({
    timeZone: zCollectionMeasurementWindow.shape.timeZone.refine((value) => {
      if (!/^[A-Za-z_]+(?:\/[A-Za-z0-9_+-]+)*$/.test(value)) return false;
      try {
        new Intl.DateTimeFormat("en", { timeZone: value });
        return true;
      } catch {
        return false;
      }
    }, "Enter an IANA time zone, such as America/Los_Angeles, or UTC."),
    start: z
      .discriminatedUnion("type", [
        zOldestSampleStartDate.strict(),
        zRelativeStartDate.extend({ components }).strict(),
        zAbsoluteStartDate.extend({ date }).strict(),
      ])
      .optional(),
    end: date.optional(),
  })
  .strict()
  .refine(
    (value) =>
      value.start?.type !== "absolute" ||
      !value.end ||
      dateKey(value.end) > dateKey(value.start.date),
    "The end must be later than the start. The end is excluded from collection.",
  );

const requirementsSchema = z
  .array(
    zCollectionRequirement
      .extend({
        profile: z.literal(heartRateProfile),
        measurementWindow: measurementWindow.optional(),
      })
      .strict(),
  )
  .max(1);

export const canEditCollection = (requirements: unknown) =>
  requirementsSchema.safeParse(requirements).success;

// Validate without transforming or dropping fields from the accepted API shape.
// A single field-level error is announced beside the grouped collection controls.
export const collectionFormSchema = z.object({
  collectionRequirements: z
    .custom<CollectionRequirement[]>()
    .superRefine((value, context) => {
      const result = requirementsSchema.safeParse(value);
      if (!result.success)
        context.addIssue({
          code: "custom",
          message: result.error.issues[0].message,
        });
    }),
});

export const newHeartRateRequirement = (): CollectionRequirement => ({
  profile: heartRateProfile,
  sourceKind: "participant-app",
});

export const collectionSummary = (requirements: CollectionRequirement[]) => {
  if (!requirements.length) return "No health measurements requested.";
  if (!canEditCollection(requirements))
    return "Review the collection settings before saving.";
  const window = requirements[0].measurementWindow;
  const start = window?.start;
  let range: string;
  switch (start?.type) {
    case "last": {
      const { year, month, day } = start.components;
      const parts = [
        [year, "year"],
        [month, "month"],
        [day, "day"],
      ] as const;
      range = `Looking back ${parts
        .filter(([amount]) => amount)
        .map(([amount, unit]) => `${amount} ${unit}${amount === 1 ? "" : "s"}`)
        .join(
          ", ",
        )} from each participant's acceptance (Gregorian calendar, ${window?.timeZone}).`;
      break;
    }
    case "absolute":
      range = `Measurements from ${start.date} (inclusive).`;
      break;
    case "oldestSample":
      range = "All available historical measurements.";
      break;
    default:
      range = "Measurements from each participant's acceptance.";
  }
  const end =
    window?.end ?
      `Before ${window.end} (exclusive).`
    : "Collection continues while enrollment and permission remain active.";
  return `Heart rate. ${range} ${end}`;
};
