//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import StudyPlatformAPIServer


extension Components.Schemas.EnrollmentResponse {
    init(_ model: Enrollment) throws {
        self.init(
            id: try model.requireId().uuidString,
            studyId: model.$study.id.uuidString,
            participantId: model.$participant.id.uuidString,
            currentRevision: model.currentRevision,
            enrolledAt: model.createdAt!,  // swiftlint:disable:this force_unwrapping
            withdrawnAt: model.withdrawnAt
        )
    }
}
