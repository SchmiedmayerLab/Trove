//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


enum DraftRevision {
    /// Accept exactly one strong entity tag; weak, wildcard and multi-tag writes are unsafe here.
    static func parse(ifMatch: String) throws -> UUID {
        guard ifMatch.count == 38, ifMatch.first == "\"", ifMatch.last == "\"",
              let revision = UUID(uuidString: String(ifMatch.dropFirst().dropLast())) else {
            throw ServerError.badRequest("If-Match must contain one quoted study draft revision")
        }
        return revision
    }
}
