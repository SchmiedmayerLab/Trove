// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { describe, expect, it } from "vitest";
import {
  enrollmentPeriodSchema,
  enrollmentPeriodSummary,
  ongoingEnrollment,
} from "./enrollmentPeriod";

describe("published enrollment period", () => {
  it("preserves duration, deadline precision and zone without resolving against the browser clock", () => {
    const value = {
      calendar: "gregorian",
      timeZone: "America/Los_Angeles",
      duration: { month: 6, day: 1 },
      end: "2027-01-01T00:00:00.123456Z",
    } as const;
    expect(enrollmentPeriodSchema.parse(value)).toEqual(value);
    expect(enrollmentPeriodSummary(value)).toContain("earlier end");
    expect(enrollmentPeriodSummary(value)).toContain(value.end);
  });
  it("keeps ongoing enrollment distinct from a zero duration", () => {
    expect(enrollmentPeriodSchema.safeParse(ongoingEnrollment()).success).toBe(
      true,
    );
    expect(
      enrollmentPeriodSchema.safeParse({
        ...ongoingEnrollment(),
        duration: { day: 0 },
      }).success,
    ).toBe(false);
  });
  it.each([
    { duration: {} },
    { duration: { year: -1 } },
    { duration: { year: 9999 } },
    { duration: { day: 1.5 } },
    { duration: { month: 1, hour: 3 } },
    { timeZone: "unknown/zone" },
    { end: "" },
    { end: "2027-02-30T00:00:00Z" },
    { end: "2027-01-01T00:00:00.1234567Z" },
    { extension: true },
  ])(
    "rejects invalid or unsupported settings without silently dropping them: %j",
    (invalid) => {
      expect(
        enrollmentPeriodSchema.safeParse({ ...ongoingEnrollment(), ...invalid })
          .success,
      ).toBe(false);
    },
  );
});
