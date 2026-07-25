//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import Spezi


final class ProfileRepository: Module, Sendable {
    let database: any Database

    init(database: any Database) {
        self.database = database
    }

    func findByIdentityProviderId(_ id: String) async throws -> Participant? {
        // swiftlint:disable:next first_where
        try await Participant.query(on: database)
            .filter(\.$identityProviderId == id)
            .first()
    }

    func create(_ participant: Participant) async throws -> Participant {
        try await participant.save(on: database)
        return participant
    }

    func update(_ participant: Participant) async throws -> Participant {
        try await participant.update(on: database)
        return participant
    }
}
