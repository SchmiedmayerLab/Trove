// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { Input } from "@schmiedmayerlab/grove-design-system";
import { useId } from "react";
import type { EnrollmentPeriod } from "@/lib/api/generated/types.gen";
import { enrollmentPeriodSummary } from "../lib/enrollmentPeriod";

export const EnrollmentPeriodControls = ({
  value,
  onChange,
}: {
  value: EnrollmentPeriod;
  onChange: (value: EnrollmentPeriod) => void;
}) => {
  const id = useId();
  return (
    <div className="flex flex-col gap-5">
      <label className="flex items-center gap-2">
        <input
          type="checkbox"
          checked={value.duration !== undefined}
          onChange={(event) => {
            const next = { ...value };
            if (event.target.checked) next.duration = { month: 6 };
            else delete next.duration;
            onChange(next);
          }}
        />
        Duration from enrollment
      </label>
      {value.duration && (
        <>
          <div className="grid max-w-xl grid-cols-3 gap-4">
            {(
              [
                ["year", "Years", 9998],
                ["month", "Months", 119988],
                ["day", "Days", 3652058],
              ] as const
            ).map(([key, label, maximum]) => (
              <div key={key} className="space-y-2">
                <label htmlFor={`${id}-${key}`}>{label}</label>
                <Input
                  id={`${id}-${key}`}
                  type="number"
                  min={0}
                  max={maximum}
                  step={1}
                  value={value.duration?.[key] ?? ""}
                  onChange={(event) => {
                    const duration = { ...value.duration };
                    duration[key] =
                      event.target.value === "" ?
                        undefined
                      : event.target.valueAsNumber;
                    onChange({ ...value, duration });
                  }}
                />
              </div>
            ))}
          </div>
          <div className="max-w-xl space-y-2">
            <label htmlFor={`${id}-zone`}>Calendar time zone</label>
            <Input
              id={`${id}-zone`}
              value={value.timeZone}
              placeholder="America/Los_Angeles"
              aria-describedby={`${id}-zone-help`}
              onChange={(event) =>
                onChange({ ...value, timeZone: event.target.value })
              }
            />
            <p id={`${id}-zone-help`} className="text-text-tertiary text-sm">
              Use an IANA time zone or UTC. Calendar durations account for month
              lengths and daylight saving time.
            </p>
          </div>
        </>
      )}
      <label className="flex items-center gap-2">
        <input
          type="checkbox"
          checked={value.end !== undefined}
          onChange={(event) => {
            const next = { ...value };
            if (event.target.checked) next.end = "";
            else delete next.end;
            onChange(next);
          }}
        />
        Fixed closing date
      </label>
      {value.end !== undefined && (
        <div className="max-w-xl space-y-2">
          <label htmlFor={`${id}-end`}>Closing time (UTC, exclusive)</label>
          <Input
            id={`${id}-end`}
            value={value.end}
            placeholder="2027-01-01T00:00:00Z"
            aria-describedby={`${id}-end-help`}
            onChange={(event) =>
              onChange({ ...value, end: event.target.value })
            }
          />
          <p id={`${id}-end-help`} className="text-text-tertiary text-sm">
            Enter YYYY-MM-DDThh:mm:ssZ. Participants cannot join at or after
            this time.
          </p>
        </div>
      )}
      <div
        role="status"
        aria-live="polite"
        className="bg-fill-tertiary rounded-lg p-4"
      >
        <p>{enrollmentPeriodSummary(value)}</p>
        <p className="text-text-tertiary mt-2 text-sm">
          Saving updates the draft. After publication, this rule applies to new
          enrollments. Existing end dates stay unchanged. Collection stops at
          the enrollment end, including while offline; already collected data
          can be sent later under its original consent.
        </p>
      </div>
    </div>
  );
};
