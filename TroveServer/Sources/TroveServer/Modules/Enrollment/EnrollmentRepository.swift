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

    func create(_ enrollment: Enrollment) async throws -> Enrollment {
        try await enrollment.save(on: database)
        return enrollment
    }

    func update(_ enrollment: Enrollment) async throws -> Enrollment {
        try await enrollment.update(on: database)
        return enrollment
    }
}
