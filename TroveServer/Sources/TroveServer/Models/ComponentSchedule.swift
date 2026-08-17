//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import GroveStudyDefinition


final class ComponentSchedule: Model, @unchecked Sendable {
    static let schema = "component_schedules"

    @ID(key: .id) var id: UUID?

    @Parent(key: "component_id") var component: Component

    @Field(key: "schedule_data") var scheduleData: StudyDefinition.ComponentSchedule

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        componentId: UUID,
        scheduleData: StudyDefinition.ComponentSchedule,
        id: UUID? = nil
    ) {
        self.id = id
        self.$component.id = componentId
        self.scheduleData = scheduleData
    }
}
