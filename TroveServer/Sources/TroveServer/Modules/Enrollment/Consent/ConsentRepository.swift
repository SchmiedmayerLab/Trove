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


final class ConsentRepository: Module, Sendable {
    let database: any Database

    init(database: any Database) {
        self.database = database
    }

    func listConsentRecords(enrollmentId: UUID) async throws -> [EnrollmentConsent] {
        try await EnrollmentConsent.query(on: database)
            .filter(\.$enrollment.$id == enrollmentId)
            .all()
    }

    func findConsentRecord(id: UUID, enrollmentId: UUID) async throws -> EnrollmentConsent? {
        // swiftlint:disable:next first_where - Fluent query builder, not a Sequence
        try await EnrollmentConsent.query(on: database)
            .filter(\.$id == id)
            .filter(\.$enrollment.$id == enrollmentId)
            .first()
    }

    func createConsentRecord(_ record: EnrollmentConsent) async throws -> EnrollmentConsent {
        try await record.save(on: database)
        return record
    }
}
