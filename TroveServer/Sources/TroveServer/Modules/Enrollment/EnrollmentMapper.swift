//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPIServer


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
