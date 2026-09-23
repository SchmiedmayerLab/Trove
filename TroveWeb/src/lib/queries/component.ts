//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import type { QueryClient } from "@tanstack/react-query";
import { draftSnapshotQueryOptions, readDraftSnapshot } from "./draft";
import { createMutationHook } from "./mutationCallbacks";
import {
  getStudiesByStudyIdComponentsOptions,
  getStudiesByStudyIdComponentsInformationalByComponentIdOptions,
  getStudiesByStudyIdComponentsQuestionnaireByComponentIdOptions,
  getStudiesByStudyIdComponentsHealthDataByComponentIdOptions,
  getStudiesByStudyIdComponentsByComponentIdSchedulesOptions,
  deleteStudiesByStudyIdComponentsByComponentIdMutation,
  postStudiesByStudyIdComponentsByComponentIdSchedulesMutation,
  postStudiesByStudyIdComponentsInformationalMutation,
  postStudiesByStudyIdComponentsQuestionnaireMutation,
  postStudiesByStudyIdComponentsHealthDataMutation,
  putStudiesByStudyIdComponentsInformationalByComponentIdMutation,
  putStudiesByStudyIdComponentsQuestionnaireByComponentIdMutation,
  putStudiesByStudyIdComponentsHealthDataByComponentIdMutation,
  putStudiesByStudyIdComponentsByComponentIdSchedulesByScheduleIdMutation,
  deleteStudiesByStudyIdComponentsByComponentIdSchedulesByScheduleIdMutation,
} from "../api/generated/@tanstack/react-query.gen";
import {
  getStudiesByStudyIdComponents,
  getStudiesByStudyIdComponentsInformationalByComponentId,
  getStudiesByStudyIdComponentsQuestionnaireByComponentId,
  getStudiesByStudyIdComponentsHealthDataByComponentId,
  getStudiesByStudyIdComponentsByComponentIdSchedules,
} from "../api/generated/sdk.gen";
import type { ComponentType } from "../api/types";

// --- Queries ---

/** Establish the editing snapshot before any component fields can be changed. */
export const loadComponentDraft = async (
  queryClient: QueryClient,
  path: { studyId: string; componentId: string },
  type: ComponentType,
) => {
  switch (type) {
    case "informational":
      await queryClient.fetchQuery(informationalRetrieveQueryOptions(path));
      break;
    case "questionnaire":
      await queryClient.fetchQuery(questionnaireRetrieveQueryOptions(path));
      break;
    case "health-data":
      await queryClient.fetchQuery(healthDataRetrieveQueryOptions(path));
      break;
  }
  if (path.componentId && type !== "health-data") {
    await queryClient.fetchQuery(scheduleListQueryOptions(path));
  }
};

/** Load the deletion target before showing confirmation, never at mutation time. */
export const readComponentDeletionSnapshot = async (
  studyId: string,
  componentId: string,
) => {
  const snapshot = await readDraftSnapshot(
    studyId,
    async (signal) =>
      (
        await getStudiesByStudyIdComponents({
          path: { studyId },
          signal,
          throwOnError: true,
        })
      ).data,
  );
  const component = snapshot.value.find((value) => value.id === componentId);
  if (!component)
    throw new Error("This component no longer exists. Reload the draft.");
  return { draftRevision: snapshot.draftRevision, name: component.name };
};

export const componentListQueryOptions = ({ studyId }: { studyId: string }) =>
  getStudiesByStudyIdComponentsOptions({ path: { studyId } });

export const informationalRetrieveQueryOptions = ({
  studyId,
  componentId,
}: {
  studyId: string;
  componentId: string;
}) =>
  draftSnapshotQueryOptions(
    studyId,
    getStudiesByStudyIdComponentsInformationalByComponentIdOptions({
      path: { studyId, componentId },
    }).queryKey,
    async (signal) =>
      componentId ?
        (
          await getStudiesByStudyIdComponentsInformationalByComponentId({
            path: { studyId, componentId },
            signal,
            throwOnError: true,
          })
        ).data
      : undefined,
  );

export const questionnaireRetrieveQueryOptions = ({
  studyId,
  componentId,
}: {
  studyId: string;
  componentId: string;
}) =>
  draftSnapshotQueryOptions(
    studyId,
    getStudiesByStudyIdComponentsQuestionnaireByComponentIdOptions({
      path: { studyId, componentId },
    }).queryKey,
    async (signal) =>
      componentId ?
        (
          await getStudiesByStudyIdComponentsQuestionnaireByComponentId({
            path: { studyId, componentId },
            signal,
            throwOnError: true,
          })
        ).data
      : undefined,
  );

export const healthDataRetrieveQueryOptions = ({
  studyId,
  componentId,
}: {
  studyId: string;
  componentId: string;
}) =>
  draftSnapshotQueryOptions(
    studyId,
    getStudiesByStudyIdComponentsHealthDataByComponentIdOptions({
      path: { studyId, componentId },
    }).queryKey,
    async (signal) =>
      componentId ?
        (
          await getStudiesByStudyIdComponentsHealthDataByComponentId({
            path: { studyId, componentId },
            signal,
            throwOnError: true,
          })
        ).data
      : undefined,
  );

export const scheduleListQueryOptions = ({
  studyId,
  componentId,
}: {
  studyId: string;
  componentId: string;
}) =>
  draftSnapshotQueryOptions(
    studyId,
    getStudiesByStudyIdComponentsByComponentIdSchedulesOptions({
      path: { studyId, componentId },
    }).queryKey,
    async (signal) =>
      (
        await getStudiesByStudyIdComponentsByComponentIdSchedules({
          path: { studyId, componentId },
          signal,
          throwOnError: true,
        })
      ).data,
  );

// --- Component mutations ---

export const useDeleteComponentMutation = createMutationHook(
  deleteStudiesByStudyIdComponentsByComponentIdMutation,
  "Error deleting component",
  "getStudiesByStudyId",
  "getStudiesByStudyIdComponents",
);

export const useCreateInformationalMutation = createMutationHook(
  postStudiesByStudyIdComponentsInformationalMutation,
  "Error creating component",
  "getStudiesByStudyId",
  "getStudiesByStudyIdComponents",
);

export const useCreateQuestionnaireMutation = createMutationHook(
  postStudiesByStudyIdComponentsQuestionnaireMutation,
  "Error creating component",
  "getStudiesByStudyId",
  "getStudiesByStudyIdComponents",
);

export const useCreateHealthDataMutation = createMutationHook(
  postStudiesByStudyIdComponentsHealthDataMutation,
  "Error creating component",
  "getStudiesByStudyId",
  "getStudiesByStudyIdComponents",
);

export const useUpdateInformationalMutation = createMutationHook(
  putStudiesByStudyIdComponentsInformationalByComponentIdMutation,
  "Error updating component",
  "getStudiesByStudyId",
  "getStudiesByStudyIdComponents",
  "getStudiesByStudyIdComponentsInformationalByComponentId",
);

export const useUpdateQuestionnaireMutation = createMutationHook(
  putStudiesByStudyIdComponentsQuestionnaireByComponentIdMutation,
  "Error updating component",
  "getStudiesByStudyId",
  "getStudiesByStudyIdComponents",
  "getStudiesByStudyIdComponentsQuestionnaireByComponentId",
);

export const useUpdateHealthDataMutation = createMutationHook(
  putStudiesByStudyIdComponentsHealthDataByComponentIdMutation,
  "Error updating component",
  "getStudiesByStudyId",
  "getStudiesByStudyIdComponents",
  "getStudiesByStudyIdComponentsHealthDataByComponentId",
);

// --- Schedule mutations ---

export const useCreateScheduleMutation = createMutationHook(
  postStudiesByStudyIdComponentsByComponentIdSchedulesMutation,
  "Error creating schedule",
  "getStudiesByStudyId",
  "getStudiesByStudyIdComponentsByComponentIdSchedules",
);

export const useUpdateScheduleMutation = createMutationHook(
  putStudiesByStudyIdComponentsByComponentIdSchedulesByScheduleIdMutation,
  "Error updating schedule",
  "getStudiesByStudyId",
  "getStudiesByStudyIdComponentsByComponentIdSchedules",
);

export const useDeleteScheduleMutation = createMutationHook(
  deleteStudiesByStudyIdComponentsByComponentIdSchedulesByScheduleIdMutation,
  "Error deleting schedule",
  "getStudiesByStudyId",
  "getStudiesByStudyIdComponentsByComponentIdSchedules",
);
