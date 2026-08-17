//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation


final class InvitationCode: Model, @unchecked Sendable {
    static let schema = "invitation_codes"

    @ID(key: .id) var id: UUID?

    @Parent(key: "study_id") var study: Study

    @Field(key: "code") var code: String

    @OptionalField(key: "expires_at") var expiresAt: Date?

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    @OptionalChild(for: \.$invitationCode) var enrollment: Enrollment?

    init() {}

    init(
        studyId: UUID,
        code: String,
        expiresAt: Date? = nil,
        id: UUID? = nil
    ) {
        self.id = id
        self.$study.id = studyId
        self.code = code
        self.expiresAt = expiresAt
    }
}


extension QueryBuilder where Model == InvitationCode {
    /// Filters to only unexpired invitation codes.
    func filterNotExpired() -> Self {
        self.group(.or) { group in
            group.filter(\.$expiresAt == nil)
            group.filter(\.$expiresAt > Date())
        }
    }
}
