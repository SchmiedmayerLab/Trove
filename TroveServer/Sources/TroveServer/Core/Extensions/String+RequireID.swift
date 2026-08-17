//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


extension String {
    func requireId() throws -> UUID {
        guard let uuid = Foundation.UUID(uuidString: self) else {
            throw ServerError.badRequest("Invalid UUID format: '\(self)'")
        }
        return uuid
    }
}
