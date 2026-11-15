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


final class EnrollmentRepository: Module, Sendable {
    let database: any Database

    init(database: any Database) {
        self.database = database
    }

    func find(id: UUID) async throws -> Enrollment? {
        try await Enrollment.find(id, on: database)
    }

    func listByStudyId(_ studyId: UUID) async throws -> [Enrollment] {
        try await Enrollment.query(on: database)
            .filter(\.$study.$id == studyId)
            .all()
    }

    func listByParticipantId(_ participantId: UUID) async throws -> [Enrollment] {
        try await Enrollment.query(on: database)
            .filter(\.$participant.$id == participantId)
            .all()
    }

    func find(participantId: UUID, studyId: UUID) async throws -> Enrollment? {
        // swiftlint:disable:next first_where - Fluent query builder, not a Sequence
        try await Enrollment.query(on: database)
            .filter(\.$participant.$id == participantId)
            .filter(\.$study.$id == studyId)
            .first()
    }

    func create(_ enrollment: Enrollment, period: EnrollmentPeriod = .ongoing) async throws -> Enrollment {
        try period.validate()
        return try await database.transaction { transaction in
            try await enrollment.save(on: transaction)
            guard let stored = try await Enrollment.find(enrollment.requireID(), on: transaction), let start = stored.createdAt else {
                throw ServerError.unexpectedError
            }
            if let end = try period.resolve(at: start) {
                stored.endsAt = end
                try await stored.save(on: transaction)
            }
            guard let result = try await Enrollment.find(stored.requireID(), on: transaction) else { throw ServerError.unexpectedError }
            return result
        }
    }

    func update(_ enrollment: Enrollment) async throws -> Enrollment {
        try await enrollment.update(on: database)
        return enrollment
    }
}
