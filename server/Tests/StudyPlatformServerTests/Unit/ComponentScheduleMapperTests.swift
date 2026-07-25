//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SpeziScheduler
import SpeziStudyDefinition
import StudyPlatformAPIServer
@testable import StudyPlatformServer
import Testing


@Suite
struct ComponentScheduleMapperTests {
    private typealias CSTime = StudyDefinition.ComponentSchedule.Time

    // MARK: - AllowedCompletionPolicy

    @Test(arguments: [
        (SpeziScheduler.AllowedCompletionPolicy.sameDay, Components.Schemas.AllowedCompletionPolicy.sameDay),
        (.afterStart, .afterStart),
        (.sameDayAfterStart, .sameDayAfterStart),
        (.duringEvent, .duringEvent),
        (.anytime, .anytime)
    ])
    func allowedCompletionPolicyRoundTrip(
        model: SpeziScheduler.AllowedCompletionPolicy,
        expected: Components.Schemas.AllowedCompletionPolicy
    ) {
        let schema = Components.Schemas.AllowedCompletionPolicy(model)
        #expect(schema == expected)
        let back = SpeziScheduler.AllowedCompletionPolicy(schema)
        #expect(back == model)
    }

    // MARK: - ScheduleTime / ComponentSchedule.Time

    @Test
    func scheduleTimeModelToSchema() {
        let model = CSTime(hour: 14, minute: 30, second: 15)
        let schema = Components.Schemas.ScheduleTime(model)
        #expect(schema.hour == 14)
        #expect(schema.minute == 30)
        #expect(schema.second == 15)
    }

    @Test
    func scheduleTimeSchemaToModel() {
        let schema = Components.Schemas.ScheduleTime(hour: 9, minute: nil, second: nil)
        let model = CSTime(schema)
        #expect(model.hour == 9)
        #expect(model.minute == 0)
        #expect(model.second == 0)
    }

    @Test
    func scheduleTimeDefaultsOmitted() {
        let model = CSTime(hour: 8, minute: 0, second: 0)
        let schema = Components.Schemas.ScheduleTime(model)
        #expect(schema.minute == nil)
        #expect(schema.second == nil)
    }

    // MARK: - Weekday

    @Test(arguments: [
        (Locale.Weekday.monday, Components.Schemas.WeeklyRepetition.WeekdayPayload.monday),
        (.tuesday, .tuesday),
        (.wednesday, .wednesday),
        (.thursday, .thursday),
        (.friday, .friday),
        (.saturday, .saturday),
        (.sunday, .sunday)
    ])
    func weekdayRoundTrip(model: Locale.Weekday, expected: Components.Schemas.WeeklyRepetition.WeekdayPayload) throws {
        let schema = try Components.Schemas.WeeklyRepetition.WeekdayPayload(model)
        #expect(schema == expected)
        let back = Locale.Weekday(schema)
        #expect(back == model)
    }

    // MARK: - StudyLifecycleEvent

    @Test
    func studyLifecycleEventEnrollment() throws {
        let schema = Components.Schemas.StudyLifecycleEvent(StudyLifecycleEvent.enrollment)
        if case .enrollment = schema {} else { Issue.record("Expected enrollment") }
        let back = try StudyLifecycleEvent(schema)
        #expect(back == .enrollment)
    }

    @Test
    func studyLifecycleEventActivation() throws {
        let schema = Components.Schemas.StudyLifecycleEvent(StudyLifecycleEvent.activation)
        if case .activation = schema {} else { Issue.record("Expected activation") }
        let back = try StudyLifecycleEvent(schema)
        #expect(back == .activation)
    }

    @Test
    func studyLifecycleEventUnenrollment() throws {
        let schema = Components.Schemas.StudyLifecycleEvent(StudyLifecycleEvent.unenrollment)
        if case .unenrollment = schema {} else { Issue.record("Expected unenrollment") }
        let back = try StudyLifecycleEvent(schema)
        #expect(back == .unenrollment)
    }

    @Test
    func studyLifecycleEventStudyEnd() throws {
        let schema = Components.Schemas.StudyLifecycleEvent(StudyLifecycleEvent.studyEnd)
        if case .studyEnd = schema {} else { Issue.record("Expected studyEnd") }
        let back = try StudyLifecycleEvent(schema)
        #expect(back == .studyEnd)
    }

    @Test
    func studyLifecycleEventCompletedTask() throws {
        let componentId = UUID()
        let schema = Components.Schemas.StudyLifecycleEvent(.completedTask(componentId: componentId))
        if case .completedTask(let value) = schema {
            #expect(value.componentId == componentId.uuidString)
        } else {
            Issue.record("Expected completedTask")
        }
        let back = try StudyLifecycleEvent(schema)
        #expect(back == .completedTask(componentId: componentId))
    }
}
