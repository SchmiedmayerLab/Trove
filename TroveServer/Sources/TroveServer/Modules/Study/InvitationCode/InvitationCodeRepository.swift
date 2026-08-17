//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import Grove


final class InvitationCodeRepository: Module, Sendable {
    let database: any Database

    init(database: any Database) {
        self.database = database
    }

    func listByStudyId(_ studyId: UUID) async throws -> [InvitationCode] {
        try await InvitationCode.query(on: database)
            .filter(\.$study.$id == studyId)
            .with(\.$enrollment)
            .all()
    }

    func codeExists(_ code: String) async throws -> Bool {
        try await InvitationCode.query(on: database)
            .filter(\.$code == code)
            .count() > 0
    }

    func find(id: UUID, studyId: UUID) async throws -> InvitationCode? {
        try await InvitationCode.query(on: database)
            .filter(\.$id == id)
            .filter(\.$study.$id == studyId)
            .with(\.$enrollment)
            .first()
    }

    func create(_ codes: [InvitationCode]) async throws -> [InvitationCode] {
        try await database.transaction { transaction in
            for code in codes {
                try await code.save(on: transaction)
            }
        }
        return codes
    }

    func delete(_ code: InvitationCode) async throws {
        try await code.delete(on: database)
    }

    /// Finds an invitation code that exists, is not expired, and has not been redeemed.
    func findValid(code: String, studyId: UUID? = nil) async throws -> InvitationCode? {
        var query = InvitationCode.query(on: database)
            .filter(\.$code == code)
            .filterNotExpired()
            .with(\.$enrollment)
        if let studyId {
            query = query.filter(\.$study.$id == studyId)
        }
        guard let invitationCode = try await query.first() else {
            return nil
        }
        return invitationCode.enrollment == nil ? invitationCode : nil
    }
}
