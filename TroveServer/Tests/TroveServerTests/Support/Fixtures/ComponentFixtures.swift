//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import GroveHealthKit
import GroveLocalization
import GroveScheduler
import GroveStudyDefinition
import TroveAPIServer
@testable import TroveServer


enum ComponentFixtures {
    @discardableResult
    static func createHealthDataComponent(
        on database: any Database,
        studyId: UUID,
        name: String = "Test Health Data"
    ) async throws -> Component {
        let componentId = UUID()
        let component = Component(
            studyId: studyId,
            data: .healthDataCollection(.init(
                id: componentId,
                sampleTypes: SampleTypesCollection([
                    SampleTypeProxy.quantity(.heartRate),
                    SampleTypeProxy.quantity(.stepCount)
                ]),
                optionalSampleTypes: SampleTypesCollection(),
                historicalDataCollection: .disabled
            )),
            name: name,
            id: componentId
        )
        try await component.save(on: database)
        return component
    }

    @discardableResult
    static func createQuestionnaireComponent(
        on database: any Database,
        studyId: UUID,
        name: String = "Test Questionnaire"
    ) async throws -> Component {
        let componentId = UUID()
        // Valid FHIR R4 Questionnaire — StudyBundle validation requires id, status, language, title, and item
        let questionnaireJSON = """
            {
              "resourceType": "Questionnaire",
              "id": "\(componentId.uuidString)",
              "status": "active",
              "language": "en-US",
              "title": "\(name)",
              "item": [{"linkId": "q1", "text": "How are you?", "type": "string"}]
            }
            """
        let component = Component(
            studyId: studyId,
            data: .questionnaire(.init([.enUS: QuestionnaireContent(questionnaire: questionnaireJSON)])),
            name: name,
            id: componentId
        )
        try await component.save(on: database)
        return component
    }

    @discardableResult
    static func createInformationalComponent(
        on database: any Database,
        studyId: UUID,
        name: String = "Test Informational"
    ) async throws -> Component {
        let component = Component(
            studyId: studyId,
            data: .informational(.init([.enUS: InformationalContent(title: "Test", content: "Content")])),
            name: name
        )
        try await component.save(on: database)
        return component
    }

    @discardableResult
    static func createSchedule(
        on database: any Database,
        componentId: UUID,
        scheduleDefinition: StudyDefinition.ComponentSchedule.ScheduleDefinition = .repeated(
            .daily(interval: 1, hour: 9, minute: 0, second: 0),
            offset: DateComponents()
        ),
        completionPolicy: AllowedCompletionPolicy = .anytime,
        notifications: StudyDefinition.ComponentSchedule.NotificationsConfig = .disabled
    ) async throws -> ComponentSchedule {
        let data = StudyDefinition.ComponentSchedule(
            id: UUID(),
            componentId: componentId,
            scheduleDefinition: scheduleDefinition,
            completionPolicy: completionPolicy,
            notifications: notifications
        )
        let schedule = ComponentSchedule(componentId: componentId, scheduleData: data)
        try await schedule.save(on: database)
        return schedule
    }
}
