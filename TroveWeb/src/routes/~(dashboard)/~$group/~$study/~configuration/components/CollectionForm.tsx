// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import {
  Checkbox,
  Field,
  Input,
  RadioGroup,
} from "@schmiedmayerlab/grove-design-system";
import { useId, useState } from "react";
import { Card, CardHeader } from "@/components/ui/Card";
import type {
  CollectionMeasurementWindow,
  CollectionRequirement,
} from "@/lib/api/generated/types.gen";
import {
  collectionSummary,
  foodSourceTypeIdentifier,
  matchesCollectionMeasurement,
  type CollectionMeasurement,
  setCollectionRequirement,
  sleepStageProfile,
  workoutProfile,
} from "../lib/collectionForm";
import type { CollectionForm as CollectionFormType } from "../lib/useCollectionForm";

interface CollectionControlsProps {
  measurements: readonly CollectionMeasurement[];
  requirements: CollectionRequirement[];
  onChange: (value: CollectionRequirement[]) => void;
}

const MeasurementControls = ({
  requirement,
  supportsWorkoutRoutes,
  onChange,
}: {
  requirement: CollectionRequirement;
  supportsWorkoutRoutes: boolean;
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
      {supportsWorkoutRoutes && (
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
  measurements,
  requirements,
  onChange,
}: CollectionControlsProps) => {
  const id = useId();
  const [search, setSearch] = useState("");
  const visible = measurements.filter((measurement) =>
    measurement.label
      .toLocaleLowerCase()
      .includes(search.trim().toLocaleLowerCase()),
  );
  return (
    <div className="flex flex-col gap-6">
      <div className="space-y-2">
        <label htmlFor={`${id}-search`}>
          Find a measurement or wearable service
        </label>
        <Input
          id={`${id}-search`}
          type="search"
          value={search}
          onChange={(event) => setSearch(event.target.value)}
        />
        <p className="text-text-tertiary text-sm" role="status">
          Showing {visible.length} of {measurements.length} measurements.
        </p>
      </div>
      {visible.map((measurement, index) => {
        const {
          profile,
          label,
          sourceTypeIdentifier,
          sourceKind = "participant-app",
          providerRegistrationId,
        } = measurement;
        const requirement = requirements.find((item) =>
          matchesCollectionMeasurement(item, measurement),
        );
        return (
          <fieldset
            key={JSON.stringify([
              profile,
              sourceKind,
              providerRegistrationId,
              sourceTypeIdentifier,
            ])}
            className="space-y-4 rounded-lg border p-4"
          >
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
                        {
                          profile,
                          sourceKind,
                          providerRegistrationId,
                          sourceTypeIdentifier,
                          timeBasis: measurement.timeBasis,
                        }
                      : undefined,
                      sourceTypeIdentifier,
                      measurement,
                    ),
                  )
                }
              />
              <label htmlFor={`${id}-${index}`}>
                Collect {label.toLowerCase()}
              </label>
            </div>
            {sourceTypeIdentifier === foodSourceTypeIdentifier && (
              <p className="text-text-tertiary text-sm">
                Food entries retain links to their nutrient records. Select each
                nutrient stream separately to collect its measurements for this
                study. The same nutrient sample keeps its identity when
                collected independently.
              </p>
            )}
            {measurement.timeBasis === "clinical-record-download" && (
              <p className="text-text-tertiary text-sm">
                Select by when HealthKit downloaded each document to the device.
                The complete original document may describe care outside this
                window.
              </p>
            )}
            {measurement.timeBasis === "cda-source-document-period" && (
              <p className="text-text-tertiary text-sm">
                Select by the document dates assigned by its creator, not care
                or download dates. Participants review and authorize each
                complete CDA document in HealthKit.
              </p>
            )}
            {measurement.isOriginalRecording && (
              <p className="text-text-tertiary text-sm">
                Includes the complete original source recording, not only a
                structured summary. Participants see this choice when they
                accept the published version.
              </p>
            )}
            {!!measurement.requiredCompanionProfiles?.length && (
              <p className="text-text-tertiary text-sm">
                Collecting this source also needs participant permission for:{" "}
                {measurement.requiredCompanionProfiles
                  .map(
                    (companion) =>
                      measurements.find(
                        (item) =>
                          item.profile === companion &&
                          item.sourceTypeIdentifier === sourceTypeIdentifier &&
                          (item.sourceKind ?? "participant-app") ===
                            sourceKind &&
                          item.providerRegistrationId ===
                            providerRegistrationId,
                      )?.label ?? "a companion output",
                  )
                  .join(", ")}
                . Each output must be selected explicitly. Selecting this output
                does not give this study access to its companions.
              </p>
            )}
            {profile === workoutProfile && sourceKind === "participant-app" && (
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
                supportsWorkoutRoutes={
                  measurement.supportsWorkoutRoutes === true
                }
                onChange={(updated) =>
                  onChange(
                    setCollectionRequirement(
                      requirements,
                      profile,
                      { ...updated, sourceTypeIdentifier },
                      sourceTypeIdentifier,
                      measurement,
                    ),
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
        <p>{collectionSummary(requirements, measurements)}</p>
        <p className="text-text-tertiary mt-2 text-sm">
          Saving updates the draft. Participants must accept the published
          version before its scope applies.
        </p>
      </div>
    </div>
  );
};

const DeviceUnitIdentifiers = ({
  checked,
  onChange,
}: {
  checked: boolean;
  onChange: (value: boolean) => void;
}) => {
  const id = useId();
  return (
    <fieldset className="mt-8 space-y-2 rounded-lg border p-4">
      <legend className="px-2 font-medium">Device unit identifiers</legend>
      <div className="flex items-center gap-3">
        <Checkbox
          id={id}
          checked={checked}
          aria-describedby={`${id}-help`}
          onCheckedChange={(value) => onChange(value === true)}
        />
        <label htmlFor={id}>
          Include device unit identifiers in study data
        </label>
      </div>
      <p id={`${id}-help`} className="text-text-tertiary text-sm">
        Unless this is selected, study data leaves out serial numbers, UDI
        production identifiers, device local identifiers and names a person gave
        a device, and original recordings that can contain them (native and
        provider recordings) are not available to this study. A record includes
        them only when every published version it was shared under does.
      </p>
    </fieldset>
  );
};

export const CollectionForm = ({
  measurements,
  form,
  onSubmit,
  disabled,
}: {
  measurements: readonly CollectionMeasurement[];
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
                measurements={measurements}
                requirements={field.value}
                onChange={field.onChange}
              />
            </div>
          )}
        />
        <Field
          control={form.control}
          name="receivesDeviceUnitIdentifiers"
          render={({ field }) => (
            <DeviceUnitIdentifiers
              checked={field.value === true}
              onChange={field.onChange}
            />
          )}
        />
      </fieldset>
    </form>
  </Card>
);
