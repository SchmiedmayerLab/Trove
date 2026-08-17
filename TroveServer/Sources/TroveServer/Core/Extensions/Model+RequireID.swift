//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation


extension Model where IDValue == UUID {
    func requireId() throws -> UUID {
        guard let id = self.id else {
            throw ServerError.internalServerError("\(Self.self) missing ID")
        }
        return id
    }
}
