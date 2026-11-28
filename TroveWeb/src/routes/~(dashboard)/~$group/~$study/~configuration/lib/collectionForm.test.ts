// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { describe, expect, it } from "vitest";
import type { CollectionMeasurementWindow } from "@/lib/api/generated/types.gen";
import {
  canEditCollection,
  makeCollectionFormSchema,
  measurementsFromProviderRegistrations,
  measurementsFromCapabilities,
  bodyWeightProfile,
  heartRateProfile,
  collectionMeasurements,
  collectionFormSchema,
  collectionSummary,
  newHeartRateRequirement,
  sleepStageProfile,
  workoutProfile,
  setCollectionRequirement,
} from "./collectionForm";

const requirement = newHeartRateRequirement();
const parseWindow = (measurementWindow: CollectionMeasurementWindow) =>
  collectionFormSchema.safeParse({
    collectionRequirements: [{ ...requirement, measurementWindow }],
  });

describe("collection authoring", () => {
  it("authors body weight independently with point-window language and all four measurements", () => {
    const weight = { ...requirement, profile: bodyWeightProfile };
    expect(
      collectionFormSchema.parse({ collectionRequirements: [weight] })
        .collectionRequirements,
    ).toEqual([weight]);
    expect(collectionSummary([weight])).toContain("Body weight.");
    expect(collectionSummary([weight])).not.toContain("overlap");
    const all = collectionMeasurements.map(({ profile }) => ({
      ...requirement,
      profile,
    }));
    expect(canEditCollection(all)).toBe(true);
    expect(canEditCollection([...all, weight])).toBe(false);
    expect(canEditCollection([{ ...weight, includeWorkoutRoutes: true }])).toBe(
      false,
    );
    const updated = setCollectionRequirement(
      [requirement],
      bodyWeightProfile,
      weight,
    );
    expect(updated).toEqual([requirement, weight]);
    expect(setCollectionRequirement(updated, bodyWeightProfile)).toEqual([
      requirement,
    ]);
  });

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

  it("submits the device unit identifier choice unchanged and accepts only a Boolean", () => {
    for (const receivesDeviceUnitIdentifiers of [true, false])
      expect(
        collectionFormSchema.parse({
          collectionRequirements: [],
          receivesDeviceUnitIdentifiers,
        }),
      ).toEqual({ collectionRequirements: [], receivesDeviceUnitIdentifiers });
    expect(
      collectionFormSchema.safeParse({
        collectionRequirements: [],
        receivesDeviceUnitIdentifiers: "yes",
      }).success,
    ).toBe(false);
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

describe("independent measurement scopes", () => {
  it("preserves heart rate when sleep is added, edited, or removed", () => {
    const heartRate = {
      ...requirement,
      measurementWindow: {
        calendar: "gregorian" as const,
        timeZone: "UTC",
        start: { type: "last" as const, components: { month: 6 } },
      },
    };
    const sleep = {
      profile: sleepStageProfile,
      sourceKind: "participant-app" as const,
    };
    const both = setCollectionRequirement(
      [heartRate],
      sleepStageProfile,
      sleep,
    );
    expect(
      collectionFormSchema.parse({ collectionRequirements: both })
        .collectionRequirements,
    ).toEqual(both);
    const edited = setCollectionRequirement(both, sleepStageProfile, {
      ...sleep,
      measurementWindow: {
        calendar: "gregorian",
        timeZone: "UTC",
        start: { type: "oldestSample" },
      },
    });
    expect(edited[0]).toEqual(heartRate);
    expect(collectionSummary(edited)).toContain("6 months");
    expect(collectionSummary(edited)).toContain(
      "All available historical measurements",
    );
    expect(collectionSummary(edited)).toContain("Complete sleep records");
    expect(setCollectionRequirement(edited, sleepStageProfile)).toEqual([
      heartRate,
    ]);
    expect(canEditCollection([sleep, sleep])).toBe(false);
  });
});

describe("workout scope", () => {
  it("requests whole workouts independently alongside heart rate and sleep", () => {
    const requirements = [
      requirement,
      { ...requirement, profile: sleepStageProfile },
      { ...requirement, profile: workoutProfile },
    ];
    expect(canEditCollection(requirements)).toBe(true);
    expect(collectionSummary(requirements)).toContain(
      "Complete workouts include all segments and statistics",
    );
    expect(setCollectionRequirement(requirements, workoutProfile)).toEqual(
      requirements.slice(0, 2),
    );
  });
});

describe("workout route scope", () => {
  it("preserves an explicit route choice and explains both choices", () => {
    for (const includeWorkoutRoutes of [false, true]) {
      const routeRequirement = {
        ...requirement,
        profile: workoutProfile,
        includeWorkoutRoutes,
      };
      const parsed = collectionFormSchema.parse({
        collectionRequirements: [routeRequirement],
      });
      expect(parsed.collectionRequirements).toEqual([routeRequirement]);
      expect(collectionSummary(parsed.collectionRequirements)).toContain(
        includeWorkoutRoutes ?
          "Precise workout location routes are collected for this study."
        : "Workout location routes are not collected for this study.",
      );
    }
  });

  it("rejects routes on a non-workout requirement", () => {
    expect(
      collectionFormSchema.safeParse({
        collectionRequirements: [
          { ...requirement, includeWorkoutRoutes: true },
        ],
      }).success,
    ).toBe(false);
  });
});

describe("server-described collection streams", () => {
  const profile = "https://example.test/recording-profile";
  const choices = [
    {
      profile,
      label: "First recording",
      sourceTypeIdentifier: "first-stream",
      effectiveTime: "interval" as const,
    },
    {
      profile,
      label: "Second recording",
      sourceTypeIdentifier: "second-stream",
      effectiveTime: "interval" as const,
    },
  ];
  const schema = makeCollectionFormSchema(choices);
  const first = {
    profile,
    sourceKind: "participant-app" as const,
    sourceTypeIdentifier: "first-stream",
  };
  const second = { ...first, sourceTypeIdentifier: "second-stream" };

  it("preserves separate source-bound requirements sharing a profile", () => {
    const value = { collectionRequirements: [first, second] };
    expect(schema.parse(value)).toEqual(value);
    expect(
      setCollectionRequirement(
        [first, second],
        profile,
        undefined,
        "first-stream",
      ),
    ).toEqual([second]);
    expect(
      schema.safeParse({ collectionRequirements: [first, first] }).success,
    ).toBe(false);
    expect(collectionSummary([first], choices)).toContain(
      "Complete interval records",
    );
    expect(collectionSummary([second], choices)).toContain("Second recording.");
    expect(collectionSummary([second], choices)).not.toContain(
      "First recording.",
    );
  });

  it("does not infer a source or accept an unadvertised stream or provider registration", () => {
    for (const requirement of [
      { profile, sourceKind: "participant-app" },
      { ...first, sourceTypeIdentifier: "other-stream" },
      {
        ...first,
        sourceKind: "server-worker",
        providerRegistrationId: "10000000-0000-4000-8000-000000000001",
      },
    ])
      expect(
        schema.safeParse({ collectionRequirements: [requirement] }).success,
      ).toBe(false);
    expect(
      makeCollectionFormSchema([]).safeParse({
        collectionRequirements: [first],
      }).success,
    ).toBe(false);
  });
});

describe("qualified wearable provider measurements", () => {
  const registrations = [
    "10000000-0000-4000-8000-000000000001",
    "10000000-0000-4000-8000-000000000002",
  ].map((id, index) => ({
    id,
    provider: "withings" as const,
    displayName: `Wearable integration ${index + 1}`,
    controller: "Study operator",
    region: "EU",
    redirects: [
      { id: "native", uri: "https://app.example.org/provider/callback" },
    ],
    capabilities: [
      {
        sourceTypeIdentifier: "getmeas:1",
        effectiveTime: "point" as const,
        measurements: [
          {
            profile: bodyWeightProfile,
            displayNameEnglish: "Body weight",
            displayNameGerman: "Körpergewicht",
          },
        ],
      },
    ],
  }));
  const choices = measurementsFromProviderRegistrations(registrations);
  const requirements = choices.map((choice) => ({
    profile: choice.profile,
    sourceKind: "server-worker" as const,
    providerRegistrationId: choice.providerRegistrationId,
    sourceTypeIdentifier: choice.sourceTypeIdentifier,
  }));
  const schema = makeCollectionFormSchema(choices);

  it("retains independent registrations even when profile and provider stream coincide", () => {
    const value = { collectionRequirements: requirements };
    expect(schema.parse(value)).toEqual(value);
    expect(collectionSummary(requirements, choices)).toContain(
      "Wearable integration 1: Body weight",
    );
    expect(collectionSummary(requirements, choices)).toContain(
      "Wearable integration 2: Body weight",
    );
    expect(
      setCollectionRequirement(
        requirements,
        bodyWeightProfile,
        undefined,
        "getmeas:1",
        choices[0],
      ),
    ).toEqual([requirements[1]]);
    const native = {
      profile: bodyWeightProfile,
      sourceKind: "participant-app" as const,
    };
    expect(
      setCollectionRequirement([...requirements, native], bodyWeightProfile),
    ).toEqual(requirements);
  });

  it("requires the exact qualified registration, source token and output profile", () => {
    const first = requirements[0];
    for (const changed of [
      { ...first, providerRegistrationId: undefined },
      {
        ...first,
        providerRegistrationId: "10000000-0000-4000-8000-000000000099",
      },
      { ...first, sourceTypeIdentifier: "getmeas:2" },
      { ...first, profile: heartRateProfile },
      { ...first, sourceKind: "participant-app" },
      { ...first, includeWorkoutRoutes: true },
    ])
      expect(
        schema.safeParse({ collectionRequirements: [changed] }).success,
      ).toBe(false);
    expect(
      schema.safeParse({ collectionRequirements: [first, first] }).success,
    ).toBe(false);
    expect(
      makeCollectionFormSchema([]).safeParse({
        collectionRequirements: [first],
      }).success,
    ).toBe(false);
  });
});

describe("original recording selection", () => {
  it("keeps mandatory producer companions explicit and does not grant them automatically", () => {
    const source = "SRSensor.accelerometer";
    const summary = "https://example.test/summary";
    const recording = "https://example.test/recording";
    const measurements = measurementsFromCapabilities([
      {
        profile: summary,
        repositoryKind: "sensorkit",
        sourceTypeIdentifier: source,
        displayNameEnglish: "Acceleration summary",
        displayNameGerman: "Zusammenfassung der Beschleunigung",
        effectiveTime: "interval",
        supportsWorkoutRoutes: false,
        isOriginalRecording: false,
        requiredCompanionProfiles: [recording],
      },
      {
        profile: recording,
        repositoryKind: "sensorkit",
        sourceTypeIdentifier: source,
        displayNameEnglish: "Original acceleration recording",
        displayNameGerman: "Originalaufzeichnung der Beschleunigung",
        effectiveTime: "interval",
        supportsWorkoutRoutes: false,
        isOriginalRecording: true,
        requiredCompanionProfiles: [summary],
      },
    ]);
    expect(measurements[0]?.requiredCompanionProfiles).toEqual([recording]);
    expect(measurements[1]?.isOriginalRecording).toBe(true);
    const selected = setCollectionRequirement(
      [],
      summary,
      {
        profile: summary,
        sourceKind: "participant-app",
        sourceTypeIdentifier: source,
      },
      source,
      measurements[0],
    );
    expect(selected).toHaveLength(1);
    expect(selected[0]?.profile).toBe(summary);
    expect(selected.some((item) => item.profile === recording)).toBe(false);
    expect(
      makeCollectionFormSchema(measurements).safeParse({
        collectionRequirements: selected,
      }).success,
    ).toBe(true);
  });
});

describe("document source dates", () => {
  it.each(["clinical-record-download", "cda-source-document-period"] as const)(
    "requires and preserves the accepted %s basis",
    (timeBasis) => {
      const profile = "https://example.test/document";
      const sourceTypeIdentifier = "exact-document-source";
      const measurements = measurementsFromCapabilities([
        {
          profile,
          sourceTypeIdentifier,
          repositoryKind: "healthkit",
          displayNameEnglish: "Original document",
          displayNameGerman: "Originaldokument",
          effectiveTime: "interval",
          supportsWorkoutRoutes: false,
          isOriginalRecording: true,
          timeBasis,
        },
      ]);
      expect(measurements[0]?.timeBasis).toBe(timeBasis);
      const requirement = {
        profile,
        sourceTypeIdentifier,
        sourceKind: "participant-app" as const,
        timeBasis,
      };
      const schema = makeCollectionFormSchema(measurements);
      expect(
        schema.parse({ collectionRequirements: [requirement] })
          .collectionRequirements,
      ).toEqual([requirement]);
      for (const wrongBasis of [undefined, "measurement-time"] as const) {
        expect(
          schema.safeParse({
            collectionRequirements: [{ ...requirement, timeBasis: wrongBasis }],
          }).success,
        ).toBe(false);
      }
    },
  );
});

describe("saved unavailable collection routes", () => {
  const withdrawn = {
    profile: bodyWeightProfile,
    sourceKind: "server-worker" as const,
    providerRegistrationId: "10000000-0000-4000-8000-000000000099",
    sourceTypeIdentifier: "getmeas:1",
    requirement: "required" as const,
    measurementWindow: { calendar: "gregorian" as const, timeZone: "UTC" },
  };
  const other = newHeartRateRequirement();
  const saved = [withdrawn, other];
  const form = makeCollectionFormSchema(collectionMeasurements, saved);
  it("keeps the saved scope intact on a level change or removal", () => {
    expect(canEditCollection(saved, collectionMeasurements, saved)).toBe(true);
    for (const rows of [
      saved,
      [{ ...withdrawn, requirement: "optional" as const }, other],
      [other],
    ]) {
      expect(
        form.parse({ collectionRequirements: rows }).collectionRequirements,
      ).toEqual(rows);
    }
  });
  it("rejects new unavailable routes and changes to their scope", () => {
    for (const row of [
      {
        ...withdrawn,
        providerRegistrationId: "10000000-0000-4000-8000-000000000098",
      },
      { ...withdrawn, measurementWindow: undefined },
      { ...withdrawn, futureSetting: true },
    ]) {
      expect(
        form.safeParse({ collectionRequirements: [row, other] }).success,
      ).toBe(false);
    }
    const malformed = { ...withdrawn, sourceTypeIdentifier: undefined };
    expect(canEditCollection([malformed], [], [malformed])).toBe(false);
  });
});
