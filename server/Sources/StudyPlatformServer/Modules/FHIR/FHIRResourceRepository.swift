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


final class FHIRResourceRepository: Module, Sendable {
    let database: any Database

    init(database: any Database) {
        self.database = database
    }

    func create(_ record: FHIRResourceRecord) async throws {
        try await record.save(on: database)
    }
}
