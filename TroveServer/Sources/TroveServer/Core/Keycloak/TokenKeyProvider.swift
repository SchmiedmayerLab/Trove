//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import JWTKit


protocol TokenKeyProvider: Sendable {
    func keys(for identifier: String) async throws -> JWTKeyCollection
}
