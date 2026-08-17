//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPIServer


extension Components.Schemas.InvitationCodeResponse {
    init(_ model: InvitationCode) throws {
        let enrollment: Enrollment? = model.$enrollment.value.flatMap { $0 }
        self.init(
            id: try model.requireId().uuidString,
            studyId: model.$study.id.uuidString,
            code: model.code,
            used: enrollment != nil,
            enrollmentId: enrollment?.id?.uuidString,
            expiresAt: model.expiresAt
        )
    }
}
