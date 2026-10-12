//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { createMutationHook } from "./mutationCallbacks";
import {
  deleteStudiesByStudyIdMutation,
  getGroupsByGroupIdStudiesOptions,
  getStudiesByStudyIdOptions,
  getStudiesByStudyIdPublishedOptions,
  postGroupsByGroupIdStudiesMutation,
  patchStudiesByStudyIdMutation,
  postStudiesByStudyIdPublishMutation,
  validateStudyDraftMutation,
} from "../api/generated/@tanstack/react-query.gen";

// --- Queries ---

export const studyListQueryOptions = ({ groupId }: { groupId: string }) =>
  getGroupsByGroupIdStudiesOptions({
    path: { groupId },
  });

export const studyResponseQueryOptions = ({ studyId }: { studyId: string }) =>
  getStudiesByStudyIdOptions({ path: { studyId } });

export const publishedStudiesQueryOptions = ({
  studyId,
}: {
  studyId: string;
}) => getStudiesByStudyIdPublishedOptions({ path: { studyId } });

// --- Mutations ---

export const useCreateStudyMutation = createMutationHook(
  postGroupsByGroupIdStudiesMutation,
  "Error creating study",
  "getGroupsByGroupIdStudies",
);

export const useUpdateStudyMutation = createMutationHook(
  patchStudiesByStudyIdMutation,
  "Error saving study",
  "getStudiesByStudyId",
  "getGroupsByGroupIdStudies",
);

export const usePublishStudyMutation = createMutationHook(
  postStudiesByStudyIdPublishMutation,
  "Error publishing study",
  "getStudiesByStudyIdPublished",
);

export const useValidateStudyMutation = createMutationHook(
  validateStudyDraftMutation,
  "Error validating study",
);

export const useDeleteStudyMutation = createMutationHook(
  deleteStudiesByStudyIdMutation,
  "Error deleting study",
  "getStudiesByStudyId",
  "getGroupsByGroupIdStudies",
);
