//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SpeziStudyDefinition
import StudyPlatformAPIServer
@testable import StudyPlatformServer
import Testing


@Suite
struct SchedulePatternMapperTests {
    private typealias CSTime = StudyDefinition.ComponentSchedule.Time
    private typealias ScheduleDef = StudyDefinition.ComponentSchedule.ScheduleDefinition
    private typealias Repetition = StudyDefinition.ComponentSchedule.ScheduleDefinition.RepetitionPattern
    private typealias OneTime = StudyDefinition.ComponentSchedule.ScheduleDefinition.OneTimeSchedule

    // MARK: - RepetitionPattern

    @Test
    func repetitionPatternDaily() throws {
        let model = Repetition.daily(interval: 2, hour: 10, minute: 15, second: 30)
        let schema = try Components.Schemas.RepetitionPattern(model)
        if case .daily(let value) = schema {
            #expect(value.interval == 2)
            #expect(value.hour == 10)
            #expect(value.minute == 15)
            #expect(value.second == 30)
        } else {
            Issue.record("Expected daily")
        }
        let back = Repetition(schema)
        #expect(back == model)
    }

    @Test
    func repetitionPatternDailyDefaultInterval() throws {
        let model = Repetition.daily(interval: 1, hour: 8, minute: 0, second: 0)
        let schema = try Components.Schemas.RepetitionPattern(model)
        if case .daily(let value) = schema {
            #expect(value.interval == nil)
            #expect(value.minute == nil)
            #expect(value.second == nil)
        } else {
            Issue.record("Expected daily")
        }
        let back = Repetition(schema)
        #expect(back == model)
    }

    @Test
    func repetitionPatternWeeklyWithWeekday() throws {
        let model = Repetition.weekly(interval: 1, weekday: .wednesday, hour: 14, minute: 0, second: 0)
        let schema = try Components.Schemas.RepetitionPattern(model)
        if case .weekly(let value) = schema {
            #expect(value.weekday == .wednesday)
            #expect(value.hour == 14)
        } else {
            Issue.record("Expected weekly")
        }
        let back = Repetition(schema)
        #expect(back == model)
    }

    @Test
    func repetitionPatternWeeklyWithoutWeekday() throws {
        let model = Repetition.weekly(interval: 2, weekday: nil, hour: 9, minute: 30, second: 0)
        let schema = try Components.Schemas.RepetitionPattern(model)
        if case .weekly(let value) = schema {
            #expect(value.weekday == nil)
            #expect(value.interval == 2)
        } else {
            Issue.record("Expected weekly")
        }
        let back = Repetition(schema)
        #expect(back == model)
    }

    @Test
    func repetitionPatternMonthlyWithDay() throws {
        let model = Repetition.monthly(interval: 1, day: 15, hour: 8, minute: 0, second: 0)
        let schema = try Components.Schemas.RepetitionPattern(model)
        if case .monthly(let value) = schema {
            #expect(value.day == 15)
            #expect(value.hour == 8)
        } else {
            Issue.record("Expected monthly")
        }
        let back = Repetition(schema)
        #expect(back == model)
    }

    @Test
    func repetitionPatternMonthlyWithoutDay() throws {
        let model = Repetition.monthly(interval: 3, day: nil, hour: 12, minute: 0, second: 0)
        let schema = try Components.Schemas.RepetitionPattern(model)
        if case .monthly(let value) = schema {
            #expect(value.day == nil)
            #expect(value.interval == 3)
        } else {
            Issue.record("Expected monthly")
        }
        let back = Repetition(schema)
        #expect(back == model)
    }

    // MARK: - OneTimeSchedule

    @Test
    func oneTimeScheduleDate() throws {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 15
        components.hour = 10

        let model = OneTime.date(components)
        let schema = Components.Schemas.OneTimeSchedule(model)
        if case .date(let value) = schema {
            #expect(value.dateComponents.year == 2026)
            #expect(value.dateComponents.month == 6)
        } else {
            Issue.record("Expected date")
        }
        let back = try OneTime(schema)
        if case .date(let backComponents) = back {
            #expect(backComponents.year == 2026)
            #expect(backComponents.month == 6)
        } else {
            Issue.record("Expected date")
        }
    }

    @Test
    func oneTimeScheduleEventWithOffset() throws {
        let model = OneTime.event(.enrollment, offsetInDays: 7, time: CSTime(hour: 9, minute: 0, second: 0))
        let schema = Components.Schemas.OneTimeSchedule(model)
        if case .event(let value) = schema {
            if case .enrollment = value.event {} else { Issue.record("Expected enrollment") }
            #expect(value.offsetInDays == 7)
            #expect(value.time?.hour == 9)
        } else {
            Issue.record("Expected event")
        }
        let back = try OneTime(schema)
        if case let .event(event, offset, time) = back {
            #expect(event == .enrollment)
            #expect(offset == 7)
            #expect(time?.hour == 9)
        } else {
            Issue.record("Expected event")
        }
    }

    @Test
    func oneTimeScheduleEventWithZeroOffset() throws {
        let model = OneTime.event(.activation, offsetInDays: 0, time: nil)
        let schema = Components.Schemas.OneTimeSchedule(model)
        if case .event(let value) = schema {
            #expect(value.offsetInDays == nil)
            #expect(value.time == nil)
        } else {
            Issue.record("Expected event")
        }
        let back = try OneTime(schema)
        if case let .event(event, offset, time) = back {
            #expect(event == .activation)
            #expect(offset == 0)
            #expect(time == nil)
        } else {
            Issue.record("Expected event")
        }
    }

    // MARK: - ScheduleDefinition

    @Test
    func scheduleDefinitionOnce() throws {
        var components = DateComponents()
        components.year = 2026
        components.month = 3

        let model = ScheduleDef.once(.date(components))
        let schema = try Components.Schemas.ScheduleDefinition(model)
        if case .once(let value) = schema {
            if case .date = value.pattern {} else { Issue.record("Expected date pattern") }
        } else {
            Issue.record("Expected once")
        }
        let back = try ScheduleDef(schema)
        if case .once(.date(let backComponents)) = back {
            #expect(backComponents.year == 2026)
        } else {
            Issue.record("Expected once date")
        }
    }

    @Test
    func scheduleDefinitionRepeated() throws {
        let model = ScheduleDef.repeated(
            .daily(interval: 1, hour: 8, minute: 0, second: 0),
            offset: DateComponents()
        )
        let schema = try Components.Schemas.ScheduleDefinition(model)
        if case .repeated(let value) = schema {
            if case .daily = value.pattern {} else { Issue.record("Expected daily pattern") }
        } else {
            Issue.record("Expected repeated")
        }
        let back = try ScheduleDef(schema)
        if case .repeated(let pattern, _) = back {
            if case let .daily(interval, hour, _, _) = pattern {
                #expect(interval == 1)
                #expect(hour == 8)
            } else {
                Issue.record("Expected daily")
            }
        } else {
            Issue.record("Expected repeated")
        }
    }

    @Test
    func scheduleDefinitionRepeatedWithOffset() throws {
        var offset = DateComponents()
        offset.day = 7

        let model = ScheduleDef.repeated(
            .weekly(interval: 1, weekday: .monday, hour: 10, minute: 0, second: 0),
            offset: offset
        )
        let schema = try Components.Schemas.ScheduleDefinition(model)
        if case .repeated(let value) = schema {
            #expect(value.offset?.day == 7)
        } else {
            Issue.record("Expected repeated")
        }
        let back = try ScheduleDef(schema)
        if case .repeated(_, let backOffset) = back {
            #expect(backOffset.day == 7)
        } else {
            Issue.record("Expected repeated")
        }
    }
}
