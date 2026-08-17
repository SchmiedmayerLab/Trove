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
}
