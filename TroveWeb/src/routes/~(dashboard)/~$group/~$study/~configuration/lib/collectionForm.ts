// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { z } from "zod";
import type { CollectionRequirement } from "@/lib/api/generated/types.gen";
import {
  zAbsoluteStartDate,
  zCollectionMeasurementWindow,
  zCollectionRequirement,
  zOldestSampleStartDate,
  zRelativeStartDate,
} from "@/lib/api/generated/zod.gen";
import {
  calendarInstant,
  calendarTimeZone,
  positiveCalendarPeriod,
} from "./calendarFields";

export const heartRateProfile =
  "https://grovealliance.org/fhir/mobile/StructureDefinition/grove-mobile-heart-rate";

export const sleepStageProfile =
  "https://grovealliance.org/fhir/mobile/StructureDefinition/grove-mobile-sleep-stage";

export const workoutProfile =
  "https://grovealliance.org/fhir/mobile/StructureDefinition/grove-mobile-workout";

export const collectionMeasurements = [
  { profile: heartRateProfile, label: "Heart rate" },
  { profile: sleepStageProfile, label: "Sleep stages" },
  { profile: workoutProfile, label: "Workouts" },
] as const;

export const setCollectionRequirement = (
  requirements: CollectionRequirement[],
  profile: string,
  requirement?: CollectionRequirement,
): CollectionRequirement[] => {
  const remaining = requirements.filter((item) => item.profile !== profile);
  return requirement ? [...remaining, requirement] : remaining;
};

// Compare at the API's microsecond precision without rounding through JavaScript Date.
const dateKey = (value: string) => {
  const [seconds, fraction = ""] = value.slice(0, -1).split(".");
  return `${seconds}.${fraction.padEnd(6, "0")}`;
};

const measurementWindow = zCollectionMeasurementWindow
  .extend({
    timeZone: calendarTimeZone,
    start: z
      .discriminatedUnion("type", [
        zOldestSampleStartDate.strict(),
        zRelativeStartDate
          .extend({ components: positiveCalendarPeriod })
          .strict(),
        zAbsoluteStartDate.extend({ date: calendarInstant }).strict(),
      ])
      .optional(),
    end: calendarInstant.optional(),
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
        profile: z.enum([heartRateProfile, sleepStageProfile, workoutProfile]),
        measurementWindow: measurementWindow.optional(),
      })
      .strict()
      .refine(
        (item) => !item.includeWorkoutRoutes || item.profile === workoutProfile,
        "Workout routes require workout collection.",
      ),
  )
  .max(3)
  .refine(
    (items) => new Set(items.map((item) => item.profile)).size === items.length,
    "Each measurement may appear only once.",
  );

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
  return requirements.map(requirementSummary).join(" ");
};

const requirementSummary = (requirement: CollectionRequirement) => {
  const window = requirement.measurementWindow;
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
  const label =
    collectionMeasurements.find(
      ({ profile }) => profile === requirement.profile,
    )?.label ?? "Measurements";
  let overlap = "";
  if (requirement.profile === workoutProfile) {
    overlap =
      " Complete workouts include all segments and statistics when the session overlaps this window, even if it starts before it or ends after it.";
    overlap +=
      requirement.includeWorkoutRoutes ?
        " Precise workout location routes are collected for this study."
      : " Workout location routes are not collected for this study.";
  } else if (requirement.profile === sleepStageProfile) {
    overlap =
      " Complete sleep records are included when they overlap this window, even if they start before it or end after it.";
  }
  return `${label}. ${range} ${end}${overlap}`;
};
