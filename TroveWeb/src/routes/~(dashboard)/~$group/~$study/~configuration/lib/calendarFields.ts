// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { z } from "zod";
import {
  zAbsoluteStartDate,
  zCollectionMeasurementWindow,
  zDateComponents,
} from "@/lib/api/generated/zod.gen";

export const calendarInstant = zAbsoluteStartDate.shape.date.refine(
  (value) =>
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$/.test(value) &&
    !value.startsWith("0000"),
  "Enter a complete UTC date and time, with at most six fractional second digits.",
);

export const positiveCalendarPeriod = zDateComponents
  .extend({
    year: z.number().int().min(0).max(9998).optional(),
    month: z.number().int().min(0).max(119988).optional(),
    day: z.number().int().min(0).max(3652058).optional(),
  })
  .strict()
  .refine(
    (value) =>
      [value.year, value.month, value.day].some((part) => (part ?? 0) > 0),
    "Enter a calendar period greater than zero.",
  );

export const calendarTimeZone =
  zCollectionMeasurementWindow.shape.timeZone.refine((value) => {
    if (!/^[A-Za-z_]+(?:\/[A-Za-z0-9_+-]+)*$/.test(value)) return false;
    try {
      new Intl.DateTimeFormat("en", { timeZone: value });
      return true;
    } catch {
      return false;
    }
  }, "Enter an IANA time zone, such as America/Los_Angeles, or UTC.");
