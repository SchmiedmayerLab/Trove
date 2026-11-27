//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SQLKit
@testable import TroveServer


extension DatabaseRuntimePrivilegesTests {
    static func withGroup(on fixture: RuntimeFixture, _ body: (String) async throws -> Void) async throws {
        let group = "trove_runtime_test_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try await fixture.admin.raw("CREATE ROLE \(ident: group) NOLOGIN").run()
        do {
            try await body(group)
        } catch {
            try await removeRole(group, databaseName: fixture.databaseName, on: fixture.admin)
            throw error
        }
        try await removeRole(group, databaseName: fixture.databaseName, on: fixture.admin)
    }
}
