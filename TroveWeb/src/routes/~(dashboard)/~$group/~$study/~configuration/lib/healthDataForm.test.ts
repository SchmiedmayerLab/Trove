// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { describe, expect, it } from "vitest";
import type { HealthDataComponentData } from "@/lib/api/generated/types.gen";
import {
  defaultValues,
  healthDataSchema,
  transformHealthDataFormToInput,
  transformResponseToForm,
} from "./healthDataForm";

const histories: Array<HealthDataComponentData["historicalDataCollection"]> = [
  undefined,
  { enabled: false },
  { enabled: true },
  { enabled: true, startDate: { type: "oldestSample" } },
  { enabled: true, startDate: { type: "last", components: { month: 6 } } },
  {
    enabled: true,
    startDate: { type: "absolute", date: "2026-01-01T00:00:00Z" },
  },
];

describe("health data authoring", () => {
  it.each(histories)(
    "preserves the historical scope when editing the name: %j",
    (history) => {
      const response = {
        id: "health-component",
        name: "Original name",
        data: {
          sampleTypes: ["HKQuantityTypeIdentifierHeartRate"],
          historicalDataCollection: history,
        },
      };
      const form = healthDataSchema.parse({
        ...transformResponseToForm(response),
        name: "Updated name",
      });
      const input = transformHealthDataFormToInput(form);
      expect(input.name).toBe("Updated name");
      expect(input.data).toEqual(response.data);
    },
  );

  it("does not enable historical collection for a new component", () => {
    const input = transformHealthDataFormToInput(
      healthDataSchema.parse({
        ...defaultValues,
        sampleTypes: ["HKQuantityTypeIdentifierHeartRate"],
      }),
    );
    expect(input.data.historicalDataCollection).toBeUndefined();
  });

  it("rejects malformed retained history instead of silently disabling it", () => {
    expect(
      healthDataSchema.safeParse({
        name: "Health data",
        sampleTypes: ["HKQuantityTypeIdentifierHeartRate"],
        historicalDataCollection: {
          enabled: true,
          startDate: { type: "absolute", date: "not-a-date" },
        },
      }).success,
    ).toBe(false);
  });
});
