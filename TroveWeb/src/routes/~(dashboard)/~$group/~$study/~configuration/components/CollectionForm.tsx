// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import {
  Checkbox,
  Field,
  Input,
  RadioGroup,
} from "@schmiedmayerlab/grove-design-system";
import { useId } from "react";
import { Card, CardHeader } from "@/components/ui/Card";
import type {
  CollectionMeasurementWindow,
  CollectionRequirement,
} from "@/lib/api/generated/types.gen";
import {
  collectionSummary,
  collectionMeasurements,
  setCollectionRequirement,
  sleepStageProfile,
  workoutProfile,
} from "../lib/collectionForm";
import type { CollectionForm as CollectionFormType } from "../lib/useCollectionForm";

interface CollectionControlsProps {
  requirements: CollectionRequirement[];
  onChange: (value: CollectionRequirement[]) => void;
}

const MeasurementControls = ({
  requirement,
  onChange,
}: {
  requirement: CollectionRequirement;
  onChange: (value: CollectionRequirement) => void;
}) => {
  const id = useId();
  const window = requirement.measurementWindow ?? {
    calendar: "gregorian",
    timeZone: "UTC",
  };
  const start = window.start;
  const setWindow = (updated: CollectionMeasurementWindow) => {
    onChange({ ...requirement, measurementWindow: updated });
  };
  return (
    <div className="flex flex-col gap-6">
      {requirement.profile === workoutProfile && (
        <div className="space-y-2">
          <div className="flex items-center gap-3">
            <Checkbox
              id={`${id}-routes`}
              checked={requirement.includeWorkoutRoutes === true}
              aria-describedby={`${id}-routes-help`}
              onCheckedChange={(checked) =>
                onChange({
                  ...requirement,
                  includeWorkoutRoutes: checked === true,
                })
              }
            />
            <label htmlFor={`${id}-routes`}>
              Include workout location routes
            </label>
          </div>
          <p id={`${id}-routes-help`} className="text-text-tertiary text-sm">
            Includes precise locations recorded during selected workouts. This
            choice is shown to participants when they accept the published
            version.
          </p>
        </div>
      )}
      <fieldset className="space-y-3">
        <legend className="mb-3 font-medium">Measurement start</legend>
        <RadioGroup
          value={start?.type ?? "acceptance"}
          onChange={(value) => {
            switch (value) {
              case "acceptance": {
                const remaining = { ...window };
                delete remaining.start;
                setWindow(remaining);
                break;
              }
              case "last":
                setWindow({
                  ...window,
                  start: { type: "last", components: { month: 6 } },
                });
                break;
              case "oldestSample":
                setWindow({ ...window, start: { type: "oldestSample" } });
                break;
              case "absolute":
                setWindow({
                  ...window,
                  start: { type: "absolute", date: "" },
                });
                break;
            }
          }}
          options={[
            { value: "acceptance", label: "From participant acceptance" },
            { value: "last", label: "Calendar lookback" },
            { value: "absolute", label: "Specific date and time" },
            { value: "oldestSample", label: "All available history" },
          ]}
        />
      </fieldset>
      {start?.type === "last" && (
        <>
          <div className="grid max-w-xl grid-cols-3 gap-4">
            {(
              [
                ["year", "Years", 9998],
                ["month", "Months", 119988],
                ["day", "Days", 3652058],
              ] as const
            ).map(([key, label, max]) => (
              <div className="space-y-2" key={key}>
                <label htmlFor={`${id}-${key}`}>{label}</label>
                <Input
                  id={`${id}-${key}`}
                  type="number"
                  min={0}
                  max={max}
                  step={1}
                  value={start.components[key] ?? ""}
                  onChange={(event) => {
                    const parts = { ...start.components };
                    parts[key] =
                      event.target.value === "" ?
                        undefined
                      : event.target.valueAsNumber;
                    setWindow({
                      ...window,
                      start: { ...start, components: parts },
                    });
                  }}
                />
              </div>
            ))}
          </div>
          <p className="text-text-tertiary text-sm">
            The lookback is resolved once when each participant accepts this
            version, using the Gregorian calendar. Reconnecting does not move
            that boundary.
          </p>
        </>
      )}
      {start?.type === "absolute" && (
        <div className="max-w-xl space-y-2">
          <label htmlFor={`${id}-start`}>Start (UTC, inclusive)</label>
          <Input
            id={`${id}-start`}
            placeholder="2026-01-01T00:00:00Z"
            value={start.date}
            onChange={(event) =>
              setWindow({
                ...window,
                start: {
                  ...start,
                  date: event.target.value,
                },
              })
            }
          />
        </div>
      )}
      <div className="max-w-xl space-y-2">
        <label htmlFor={`${id}-zone`}>Calendar time zone</label>
        <Input
          id={`${id}-zone`}
          value={window.timeZone}
          placeholder="America/Los_Angeles"
          aria-describedby={`${id}-zone-help`}
          onChange={(event) =>
            setWindow({ ...window, timeZone: event.target.value })
          }
        />
        <p id={`${id}-zone-help`} className="text-text-tertiary text-sm">
          Use an IANA time zone or UTC for calendar lookbacks. Enter fixed times
          in UTC as YYYY-MM-DDThh:mm:ssZ; fractional seconds are optional.
        </p>
      </div>
      <div className="max-w-xl space-y-2">
        <label htmlFor={`${id}-end`}>End (UTC, exclusive, optional)</label>
        <Input
          id={`${id}-end`}
          placeholder="2027-01-01T00:00:00Z"
          value={window.end ?? ""}
          aria-describedby={`${id}-end-help`}
          onChange={(event) => {
            const remaining = { ...window };
            delete remaining.end;
            setWindow(
              event.target.value ?
                { ...remaining, end: event.target.value }
              : remaining,
            );
          }}
        />
        <p id={`${id}-end-help`} className="text-text-tertiary text-sm">
          Leave empty to continue while enrollment and permission remain active.
          Measurements exactly at this time are excluded.
        </p>
      </div>
    </div>
  );
};

const CollectionControls = ({
  requirements,
  onChange,
}: CollectionControlsProps) => {
  const id = useId();
  return (
    <div className="flex flex-col gap-6">
      {collectionMeasurements.map(({ profile, label }, index) => {
        const requirement = requirements.find(
          (item) => item.profile === profile,
        );
        return (
          <fieldset key={profile} className="space-y-4 rounded-lg border p-4">
            <legend className="px-2 font-medium">{label}</legend>
            <div className="flex items-center gap-3">
              <Checkbox
                id={`${id}-${index}`}
                checked={!!requirement}
                onCheckedChange={(checked) =>
                  onChange(
                    setCollectionRequirement(
                      requirements,
                      profile,
                      checked === true ?
                        { profile, sourceKind: "participant-app" }
                      : undefined,
                    ),
                  )
                }
              />
              <label htmlFor={`${id}-${index}`}>
                Collect {label.toLowerCase()}
              </label>
            </div>
            {profile === workoutProfile && (
              <p className="text-text-tertiary text-sm">
                Complete workouts include all segments and statistics when the
                session overlaps the selected window. They may start before it
                or end after it.
              </p>
            )}
            {profile === sleepStageProfile && (
              <p className="text-text-tertiary text-sm">
                Sleep records are included in full when they overlap the
                selected window. They may start before it or end after it.
              </p>
            )}
            {requirement && (
              <MeasurementControls
                requirement={requirement}
                onChange={(updated) =>
                  onChange(
                    setCollectionRequirement(requirements, profile, updated),
                  )
                }
              />
            )}
          </fieldset>
        );
      })}
      <div
        className="bg-fill-tertiary rounded-lg p-4"
        role="status"
        aria-live="polite"
      >
        <h3 className="mb-2 font-medium">Collection scope</h3>
        <p>{collectionSummary(requirements)}</p>
        <p className="text-text-tertiary mt-2 text-sm">
          Saving updates the draft. Participants must accept the published
          version before its scope applies.
        </p>
      </div>
    </div>
  );
};

export const CollectionForm = ({
  form,
  onSubmit,
  disabled,
}: {
  form: CollectionFormType;
  onSubmit: () => void;
  disabled: boolean;
}) => (
  <Card>
    <CardHeader
      title="Health collection"
      description="Choose which measurements this study requests and the time period they cover."
    />
    <form onSubmit={onSubmit} noValidate className="p-(--card-padding)">
      <fieldset disabled={disabled}>
        <Field
          control={form.control}
          name="collectionRequirements"
          render={({ field }) => (
            <div
              id={field.id}
              aria-invalid={field["aria-invalid"]}
              aria-errormessage={field["aria-errormessage"]}
            >
              <CollectionControls
                requirements={field.value}
                onChange={field.onChange}
              />
            </div>
          )}
        />
      </fieldset>
    </form>
  </Card>
);
