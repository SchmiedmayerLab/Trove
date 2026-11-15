// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { z } from "zod";
import type { EnrollmentPeriod } from "@/lib/api/generated/types.gen";
import { zEnrollmentPeriod } from "@/lib/api/generated/zod.gen";
import {
  calendarInstant,
  calendarTimeZone,
  positiveCalendarPeriod,
} from "./calendarFields";

const periodSchema = zEnrollmentPeriod
  .extend({
    timeZone: calendarTimeZone,
    duration: positiveCalendarPeriod.optional(),
    end: calendarInstant.optional(),
  })
  .strict();

export const enrollmentPeriodSchema = z
  .custom<EnrollmentPeriod>()
  .superRefine((value, context) => {
    const result = periodSchema.safeParse(value);
    if (!result.success)
      context.addIssue({
        code: "custom",
        message: result.error.issues[0].message,
      });
  });

export const ongoingEnrollment = (): EnrollmentPeriod => ({
  calendar: "gregorian",
  timeZone: "UTC",
});

export const enrollmentPeriodSummary = (period: EnrollmentPeriod) => {
  if (!periodSchema.safeParse(period).success)
    return "Review the enrollment period before saving.";
  if (!period.duration && !period.end)
    return "Ongoing enrollment, with no scheduled end.";
  const parts: string[] = [];
  if (period.duration) {
    const values = (["year", "month", "day"] as const).flatMap((unit) => {
      const amount = period.duration?.[unit];
      return amount ? [`${amount} ${unit}${amount === 1 ? "" : "s"}`] : [];
    });
    parts.push(
      `${values.join(", ")} from enrollment (Gregorian calendar, ${period.timeZone}).`,
    );
  }
  if (period.end) parts.push(`Ends before ${period.end}.`);
  if (period.duration && period.end) parts.push("The earlier end applies.");
  return parts.join(" ");
};
