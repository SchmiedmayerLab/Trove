//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { getStudiesByStudyIdEnrollmentsOptions } from "../api/generated/@tanstack/react-query.gen";

export const enrollmentListQueryOptions = ({ studyId }: { studyId: string }) =>
  getStudiesByStudyIdEnrollmentsOptions({ path: { studyId } });
