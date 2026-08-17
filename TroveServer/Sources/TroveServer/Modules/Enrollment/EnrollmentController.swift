//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPIServer


extension Controller {
    func getStudiesStudyIdEnrollments(
        _ input: Operations.GetStudiesStudyIdEnrollments.Input
    ) async throws -> Operations.GetStudiesStudyIdEnrollments.Output {
        let studyId = try input.path.studyId.requireId()
        let enrollments = try await enrollmentService.listEnrollments(studyId: studyId)
        return .ok(.init(body: .json(try enrollments.map { try .init($0) })))
    }
}
