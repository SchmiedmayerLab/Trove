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


final class FHIRResourceRepository: Module, Sendable {
    let database: any Database

    init(database: any Database) {
        self.database = database
    }

    func create(_ record: FHIRResourceRecord) async throws {
        try await record.save(on: database)
    }

    func listObservations(participantID: UUID, code: String, start: Date, end: Date) async throws -> [FHIRResourceRecord] {
        try await FHIRResourceRecord.query(on: database)
            .filter(\.$id.$participantID == participantID)
            .filter(\.$resourceType == "Observation")
            .filter(\.$code == code)
            .filter(\.$id.$time >= start)
            .filter(\.$id.$time <= end)
            .sort("time", .ascending)
            .all()
    }
}
