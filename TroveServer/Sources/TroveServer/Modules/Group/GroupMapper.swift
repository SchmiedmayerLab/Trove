//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPIServer


extension Components.Schemas.GroupResponse {
    init(_ model: Group) throws {
        self.init(
            id: try model.requireId().uuidString,
            name: model.name,
            icon: model.icon
        )
    }
}
