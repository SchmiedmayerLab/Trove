//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import StudyPlatformAPIServer


extension Components.Schemas.GroupResponse {
    init(_ model: Group) throws {
        self.init(
            id: try model.requireId().uuidString,
            name: model.name,
            icon: model.icon
        )
    }
}
