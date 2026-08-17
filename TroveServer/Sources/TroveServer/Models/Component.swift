//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import GroveLocalization
import GroveStudyDefinition
import TroveAPIServer


enum ComponentData: Codable, Sendable, Hashable {
    case informational(LocalizationsDictionary<InformationalContent>)
    case questionnaire(LocalizationsDictionary<QuestionnaireContent>)
    case healthDataCollection(StudyDefinition.HealthDataCollectionComponent)

    var type: ComponentType {
        switch self {
        case .informational: .informational
        case .questionnaire: .questionnaire
        case .healthDataCollection: .healthDataCollection
        }
    }
}


final class Component: Model, @unchecked Sendable {
    static let schema = "components"

    @ID(key: .id) var id: UUID?

    @Parent(key: "study_id") var study: Study

    @Field(key: "data") var data: ComponentData

    @Field(key: "name") var name: String

    @Field(key: "type") var type: ComponentType

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    @Children(for: \.$component) var schedules: [ComponentSchedule]

    init() {}

    init(
        studyId: UUID,
        data: ComponentData,
        name: String,
        id: UUID? = nil
    ) {
        self.id = id
        self.$study.id = studyId
        self.data = data
        self.type = data.type
        self.name = name
    }
}
