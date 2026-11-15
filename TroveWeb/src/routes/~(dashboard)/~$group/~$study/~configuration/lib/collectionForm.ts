// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { z } from "zod";
import type {
  CollectionCapability,
  CollectionRequirement,
  ProviderRegistration,
} from "@/lib/api/generated/types.gen";
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

export const bodyWeightProfile =
  "https://grovealliance.org/fhir/mobile/StructureDefinition/grove-mobile-body-weight";

export const sleepStageProfile =
  "https://grovealliance.org/fhir/mobile/StructureDefinition/grove-mobile-sleep-stage";

export const foodSourceTypeIdentifier = "HKCorrelationTypeIdentifierFood";

export const workoutProfile =
  "https://grovealliance.org/fhir/mobile/StructureDefinition/grove-mobile-workout";

export interface CollectionMeasurement {
  profile: string;
  label: string;
  sourceTypeIdentifier?: string;
  sourceKind?: CollectionRequirement["sourceKind"];
  providerRegistrationId?: string;
  effectiveTime?: CollectionCapability["effectiveTime"];
  supportsWorkoutRoutes?: boolean;
  isOriginalRecording?: boolean;
  timeBasis?: NonNullable<CollectionCapability["timeBasis"]>;
  requiredCompanionProfiles?: string[];
}

export const measurementsFromCapabilities = (
  capabilities: CollectionCapability[],
): CollectionMeasurement[] =>
  capabilities.map((capability) => ({
    profile: capability.profile,
    label: capability.displayNameEnglish,
    sourceTypeIdentifier: capability.sourceTypeIdentifier,
    effectiveTime: capability.effectiveTime,
    supportsWorkoutRoutes: capability.supportsWorkoutRoutes,
    isOriginalRecording: capability.isOriginalRecording,
    timeBasis: capability.timeBasis,
    requiredCompanionProfiles: capability.requiredCompanionProfiles,
  }));

export const measurementsFromProviderRegistrations = (
  registrations: ProviderRegistration[],
): CollectionMeasurement[] =>
  registrations.flatMap((registration) =>
    registration.capabilities.flatMap((capability) =>
      capability.measurements.map((measurement) => ({
        profile: measurement.profile,
        label: `${registration.displayName}: ${measurement.displayNameEnglish}`,
        sourceKind: "server-worker" as const,
        providerRegistrationId: registration.id,
        sourceTypeIdentifier: capability.sourceTypeIdentifier,
        effectiveTime: capability.effectiveTime,
        supportsWorkoutRoutes: false,
      })),
    ),
  );

export const matchesCollectionMeasurement = (
  requirement: CollectionRequirement,
  measurement: CollectionMeasurement,
) =>
  requirement.profile === measurement.profile &&
  requirement.sourceKind === (measurement.sourceKind ?? "participant-app") &&
  requirement.providerRegistrationId === measurement.providerRegistrationId &&
  (requirement.sourceTypeIdentifier === measurement.sourceTypeIdentifier ||
    (requirement.sourceKind === "participant-app" &&
      requirement.sourceTypeIdentifier === undefined &&
      [
        heartRateProfile,
        bodyWeightProfile,
        sleepStageProfile,
        workoutProfile,
      ].includes(requirement.profile)));

export const collectionMeasurements: readonly CollectionMeasurement[] = [
  { profile: heartRateProfile, label: "Heart rate" },
  { profile: bodyWeightProfile, label: "Body weight" },
  { profile: sleepStageProfile, label: "Sleep stages" },
  { profile: workoutProfile, label: "Workouts", supportsWorkoutRoutes: true },
];

export const setCollectionRequirement = (
  requirements: CollectionRequirement[],
  profile: string,
  requirement?: CollectionRequirement,
  sourceTypeIdentifier = requirement?.sourceTypeIdentifier,
  qualification: Pick<
    CollectionMeasurement,
    "sourceKind" | "providerRegistrationId"
  > = {},
): CollectionRequirement[] => {
  const sourceKind =
    qualification.sourceKind ?? requirement?.sourceKind ?? "participant-app";
  const registration =
    qualification.providerRegistrationId ?? requirement?.providerRegistrationId;
  const remaining = requirements.filter(
    (item) =>
      item.sourceKind !== sourceKind ||
      item.providerRegistrationId !== registration ||
      item.profile !== profile ||
      (sourceTypeIdentifier !== undefined &&
        item.sourceTypeIdentifier !== undefined &&
        item.sourceTypeIdentifier !== sourceTypeIdentifier),
  );
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

const requirementsSchema = (measurements: readonly CollectionMeasurement[]) =>
  z
    .array(
      zCollectionRequirement
        .extend({
          profile: z
            .string()
            .refine(
              (value) => measurements.some(({ profile }) => value === profile),
              "Unsupported collection measurement.",
            ),
          measurementWindow: measurementWindow.optional(),
        })
        .strict()
        .refine(
          (item) =>
            measurements.some(
              (measurement) =>
                matchesCollectionMeasurement(item, measurement) &&
                (item.timeBasis ?? "measurement-time") ===
                  (measurement.timeBasis ?? "measurement-time"),
            ),
          "Choose the exact source stream for this measurement.",
        )
        .refine(
          (item) =>
            !item.includeWorkoutRoutes ||
            measurements.some(
              (measurement) =>
                matchesCollectionMeasurement(item, measurement) &&
                measurement.supportsWorkoutRoutes === true,
            ),
          "Workout routes require workout collection.",
        ),
    )
    .max(512)
    .refine(
      (items) =>
        new Set(
          items.map((item) =>
            JSON.stringify([
              item.profile,
              item.sourceKind,
              item.providerRegistrationId ?? null,
              item.sourceTypeIdentifier ?? null,
            ]),
          ),
        ).size === items.length,
      "Each measurement may appear only once.",
    );

export const canEditCollection = (
  requirements: unknown,
  measurements: readonly CollectionMeasurement[] = collectionMeasurements,
) => requirementsSchema(measurements).safeParse(requirements).success;

// Validate without transforming or dropping fields from the accepted API shape.
// A single field-level error is announced beside the grouped collection controls.
export const makeCollectionFormSchema = (
  measurements: readonly CollectionMeasurement[],
) =>
  z.object({
    collectionRequirements: z
      .custom<CollectionRequirement[]>()
      .superRefine((value, context) => {
        const result = requirementsSchema(measurements).safeParse(value);
        if (!result.success)
          context.addIssue({
            code: "custom",
            message: result.error.issues[0].message,
          });
      }),
  });

export const collectionFormSchema = makeCollectionFormSchema(
  collectionMeasurements,
);

export const newHeartRateRequirement = (): CollectionRequirement => ({
  profile: heartRateProfile,
  sourceKind: "participant-app",
});

export const collectionSummary = (
  requirements: CollectionRequirement[],
  measurements: readonly CollectionMeasurement[] = collectionMeasurements,
) => {
  if (!requirements.length) return "No health measurements requested.";
  if (!canEditCollection(requirements, measurements))
    return "Review the collection settings before saving.";
  return requirements
    .map((requirement) => requirementSummary(requirement, measurements))
    .join(" ");
};

const requirementSummary = (
  requirement: CollectionRequirement,
  measurements: readonly CollectionMeasurement[],
) => {
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
  const measurement = measurements.find((candidate) =>
    matchesCollectionMeasurement(requirement, candidate),
  );
  const label = measurement?.label ?? "Measurements";
  let overlap = "";
  if (requirement.profile === workoutProfile) {
    overlap =
      requirement.sourceKind === "participant-app" ?
        " Complete workouts include all segments and statistics when the session overlaps this window, even if it starts before it or ends after it."
      : " Complete workout records are included when they overlap this window, even if they start before it or end after it.";
    if (requirement.sourceKind === "participant-app")
      overlap +=
        requirement.includeWorkoutRoutes ?
          " Precise workout location routes are collected for this study."
        : " Workout location routes are not collected for this study.";
  } else if (requirement.profile === sleepStageProfile) {
    overlap =
      " Complete sleep records are included when they overlap this window, even if they start before it or end after it.";
  }
  const effectiveTime = measurement?.effectiveTime;
  if (!overlap && effectiveTime && effectiveTime !== "point") {
    overlap =
      " Complete interval records are included when they overlap this window, even if they start before it or end after it.";
  }
  return `${label}. ${range} ${end}${overlap}`;
};
