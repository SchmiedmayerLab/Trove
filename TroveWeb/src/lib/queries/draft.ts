// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import { queryOptions, type QueryKey } from "@tanstack/react-query";
import { useEffect, useRef } from "react";
import { getStudiesByStudyId } from "../api/generated/sdk.gen";

export const draftHeaders = (revision: string) => ({
  "If-Match": `"${revision}"`,
});

export const readDraftSnapshot = async <T>(
  studyId: string,
  read: (signal: AbortSignal) => Promise<T>,
  signal = new AbortController().signal,
) => {
  const { data: study } = await getStudiesByStudyId({
    path: { studyId },
    signal,
    throwOnError: true,
  });
  return { draftRevision: study.draftRevision, value: await read(signal) };
};

/** Read the revision before fresh child data; never pair a new revision with cached child data. */
export const draftSnapshotQueryOptions = <T>(
  studyId: string,
  queryKey: QueryKey,
  read: (signal: AbortSignal) => Promise<T>,
) =>
  queryOptions({
    queryKey: [...queryKey, { draftSnapshot: true }],
    queryFn: ({ signal }) => readDraftSnapshot(studyId, read, signal),
  });

interface FormSnapshot<T> {
  scope: string;
  value: T;
}

export const selectFormSnapshot = <T>(
  previous: FormSnapshot<T> | undefined,
  snapshot: T | undefined,
  scope: string,
  isDirty: boolean,
): FormSnapshot<T> | undefined => {
  if (snapshot === undefined)
    return previous?.scope === scope ? previous : undefined;
  if (previous?.scope === scope && (isDirty || previous.value === snapshot))
    return previous;
  return { scope, value: snapshot };
};

/** Keep the values and revision that populated an editing session together. */
export const useDraftFormSnapshot = <T>(
  snapshot: T | undefined,
  scope: string,
  isDirty: boolean,
  reset: (snapshot: T) => void,
) => {
  const capturedRef = useRef<FormSnapshot<T> | undefined>(undefined);
  useEffect(() => {
    const next = selectFormSnapshot(
      capturedRef.current,
      snapshot,
      scope,
      isDirty,
    );
    if (next !== capturedRef.current) {
      capturedRef.current = next;
      if (next) reset(next.value);
    }
  }, [snapshot, scope, isDirty, reset]);
  return () => {
    if (capturedRef.current?.scope !== scope) {
      throw new Error(
        "Wait for the study draft to load before making changes.",
      );
    }
    return capturedRef.current.value;
  };
};
