//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import { getStudiesByStudyIdEnrollmentsOptions } from "../api/generated/@tanstack/react-query.gen";

export const enrollmentListQueryOptions = ({ studyId }: { studyId: string }) =>
  getStudiesByStudyIdEnrollmentsOptions({ path: { studyId } });
