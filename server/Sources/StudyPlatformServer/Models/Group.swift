//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation


final class Group: Model, @unchecked Sendable {
    static let schema = "groups"

    @ID(key: .id) var id: UUID?

    @Field(key: "name") var name: String

    @Field(key: "icon") var icon: String

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    @Children(for: \.$group) var studies: [Study]

    init() {}

    init(
        name: String,
        icon: String,
        id: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.icon = icon
    }
}
