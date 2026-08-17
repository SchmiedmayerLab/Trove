//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
@testable import TroveServer


enum GroupFixtures {
    @discardableResult
    static func createGroup(
        on database: any Database,
        id: UUID = UUID(),
        name: String = "Test Group",
        icon: String = "heart.fill"
    ) async throws -> Group {
        let group = Group(name: name, icon: icon, id: id)
        try await group.save(on: database)
        return group
    }
}
