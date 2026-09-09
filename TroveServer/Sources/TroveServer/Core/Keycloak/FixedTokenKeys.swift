//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import JWTKit


/// Explicitly supplied fixed trust, used by isolated signing fixtures.
struct FixedTokenKeys: TokenKeyProvider {
    let collection: JWTKeyCollection
    let identifiers: Set<String>

    func keys(for identifier: String) async throws -> JWTKeyCollection {
        guard identifiers.contains(identifier) else {
            throw ServerError.invalidToken
        }
        return collection
    }
}
