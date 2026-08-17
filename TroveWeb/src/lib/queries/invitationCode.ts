//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { createMutationHook } from "./mutationCallbacks";
import {
  deleteStudiesByStudyIdInvitationCodesByCodeIdMutation,
  getStudiesByStudyIdInvitationCodesOptions,
  postStudiesByStudyIdInvitationCodesMutation,
} from "../api/generated/@tanstack/react-query.gen";

export const invitationCodeListQueryOptions = ({
  studyId,
}: {
  studyId: string;
}) => getStudiesByStudyIdInvitationCodesOptions({ path: { studyId } });

export const useCreateInvitationCodesMutation = createMutationHook(
  postStudiesByStudyIdInvitationCodesMutation,
  "Error generating invitation codes",
  "getStudiesByStudyIdInvitationCodes",
);

export const useDeleteInvitationCodeMutation = createMutationHook(
  deleteStudiesByStudyIdInvitationCodesByCodeIdMutation,
  "Error deleting invitation code",
  "getStudiesByStudyIdInvitationCodes",
);
