//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
@testable import TroveServer


struct DraftRevisionTests {
    @Test
    func acceptsOneStrongRevision() throws {
        let revision = UUID()
        #expect(try DraftRevision.parse(ifMatch: "\"\(revision.uuidString)\"") == revision)
    }

    @Test(arguments: [
        "", "*", "invalid", "00000000-0000-0000-0000-000000000001",
        "W/\"00000000-0000-0000-0000-000000000001\"",
        "\"00000000-0000-0000-0000-000000000001\", \"00000000-0000-0000-0000-000000000002\""
    ])
    func rejectsAmbiguousPreconditions(_ value: String) {
        #expect {
            try DraftRevision.parse(ifMatch: value)
        } throws: { error in
            (error as? ServerError)?.status.code == 400
        }
    }
}
