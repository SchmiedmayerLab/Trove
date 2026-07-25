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


// MARK: - Top-Level: ComponentSchedule

extension Components.Schemas.ComponentSchedule {
    init(_ model: ComponentSchedule) throws {
        let notificationEnabled: Bool
        switch model.scheduleData.notifications {
        case .disabled:
            notificationEnabled = false
        case .enabled:
            notificationEnabled = true
        }
        self.init(
            id: try model.requireId().uuidString,
            scheduleDefinition: try .init(model.scheduleData.scheduleDefinition),
            completionPolicy: .init(model.scheduleData.completionPolicy),
            notification: notificationEnabled
        )
    }
}

extension StudyDefinition.ComponentSchedule {
    init(id: UUID, componentId: UUID, _ schema: Components.Schemas.ComponentScheduleInput) throws {
        self.init(
            id: id,
            componentId: componentId,
            scheduleDefinition: try .init(schema.scheduleDefinition),
            completionPolicy: .init(schema.completionPolicy),
            notifications: schema.notification ? .enabled(thread: .task, time: nil) : .disabled
        )
    }
}


// MARK: - ScheduleDefinition

extension Components.Schemas.ScheduleDefinition {
    init(_ model: StudyDefinition.ComponentSchedule.ScheduleDefinition) throws {
        switch model {
        case .once(let schedule):
            self = .once(.init(_type: .once, pattern: .init(schedule)))
        case let .repeated(pattern, offset):
            self = .repeated(.init(_type: .repeated, pattern: try .init(pattern), offset: .init(offset)))
        }
    }
}

extension StudyDefinition.ComponentSchedule.ScheduleDefinition {
    init(_ schema: Components.Schemas.ScheduleDefinition) throws {
        switch schema {
        case .once(let value):
            self = .once(try .init(value.pattern))
        case .repeated(let value):
            self = .repeated(.init(value.pattern), offset: value.offset.map { Foundation.DateComponents($0) } ?? Foundation.DateComponents())
        }
    }
}


// MARK: - OneTimeSchedule

extension Components.Schemas.OneTimeSchedule {
    init(_ model: StudyDefinition.ComponentSchedule.ScheduleDefinition.OneTimeSchedule) {
        switch model {
        case .date(let components):
            self = .date(.init(_type: .date, dateComponents: .init(components)))
        case let .event(event, offsetInDays, time):
            self = .event(.init(
                _type: .event,
                event: .init(event),
                offsetInDays: offsetInDays == 0 ? nil : offsetInDays,
                time: time.map { .init($0) }
            ))
        }
    }
}

extension StudyDefinition.ComponentSchedule.ScheduleDefinition.OneTimeSchedule {
    init(_ schema: Components.Schemas.OneTimeSchedule) throws {
        switch schema {
        case .date(let value):
            self = .date(Foundation.DateComponents(value.dateComponents))
        case .event(let value):
            self = .event(
                try StudyLifecycleEvent(value.event),
                offsetInDays: value.offsetInDays ?? 0,
                time: value.time.map { StudyDefinition.ComponentSchedule.Time($0) }
            )
        }
    }
}


// MARK: - RepetitionPattern

extension Components.Schemas.RepetitionPattern {
    init(_ model: StudyDefinition.ComponentSchedule.ScheduleDefinition.RepetitionPattern) throws {
        switch model {
        case let .daily(interval, hour, minute, second):
            self = .daily(.init(
                _type: .daily,
                interval: interval == 1 ? nil : interval,
                hour: hour,
                minute: minute == 0 ? nil : minute,
                second: second == 0 ? nil : second
            ))
        case let .weekly(interval, weekday, hour, minute, second):
            self = .weekly(.init(
                _type: .weekly,
                interval: interval == 1 ? nil : interval,
                weekday: try weekday.map { try .init($0) },
                hour: hour,
                minute: minute == 0 ? nil : minute,
                second: second == 0 ? nil : second
            ))
        case let .monthly(interval, day, hour, minute, second):
            self = .monthly(.init(
                _type: .monthly,
                interval: interval == 1 ? nil : interval,
                day: day,
                hour: hour,
                minute: minute == 0 ? nil : minute,
                second: second == 0 ? nil : second
            ))
        }
    }
}

extension StudyDefinition.ComponentSchedule.ScheduleDefinition.RepetitionPattern {
    init(_ schema: Components.Schemas.RepetitionPattern) {
        switch schema {
        case .daily(let value):
            self = .daily(
                interval: value.interval ?? 1,
                hour: value.hour,
                minute: value.minute ?? 0,
                second: value.second ?? 0
            )
        case .weekly(let value):
            self = .weekly(
                interval: value.interval ?? 1,
                weekday: value.weekday.map { Locale.Weekday($0) },
                hour: value.hour,
                minute: value.minute ?? 0,
                second: value.second ?? 0
            )
        case .monthly(let value):
            self = .monthly(
                interval: value.interval ?? 1,
                day: value.day,
                hour: value.hour,
                minute: value.minute ?? 0,
                second: value.second ?? 0
            )
        }
    }
}


// MARK: - StudyLifecycleEvent

extension Components.Schemas.StudyLifecycleEvent {
    init(_ model: StudyLifecycleEvent) {
        switch model {
        case .enrollment:
            self = .enrollment(.init(_type: .enrollment))
        case .activation:
            self = .activation(.init(_type: .activation))
        case .unenrollment:
            self = .unenrollment(.init(_type: .unenrollment))
        case .studyEnd:
            self = .studyEnd(.init(_type: .studyEnd))
        case .completedTask(let componentId):
            self = .completedTask(.init(_type: .completedTask, componentId: componentId.uuidString))
        }
    }
}

extension StudyLifecycleEvent {
    init(_ schema: Components.Schemas.StudyLifecycleEvent) throws {
        switch schema {
        case .enrollment:
            self = .enrollment
        case .activation:
            self = .activation
        case .unenrollment:
            self = .unenrollment
        case .studyEnd:
            self = .studyEnd
        case .completedTask(let value):
            guard let id = UUID(uuidString: value.componentId) else {
                throw ServerError.badRequest("Invalid UUID for completedTask componentId: '\(value.componentId)'")
            }
            self = .completedTask(componentId: id)
        }
    }
}


// MARK: - AllowedCompletionPolicy

extension Components.Schemas.AllowedCompletionPolicy {
    init(_ model: SpeziScheduler.AllowedCompletionPolicy) {
        switch model {
        case .sameDay: self = .sameDay
        case .afterStart: self = .afterStart
        case .sameDayAfterStart: self = .sameDayAfterStart
        case .duringEvent: self = .duringEvent
        case .anytime: self = .anytime
        }
    }
}

extension SpeziScheduler.AllowedCompletionPolicy {
    init(_ schema: Components.Schemas.AllowedCompletionPolicy) {
        switch schema {
        case .sameDay: self = .sameDay
        case .afterStart: self = .afterStart
        case .sameDayAfterStart: self = .sameDayAfterStart
        case .duringEvent: self = .duringEvent
        case .anytime: self = .anytime
        }
    }
}


// MARK: - ScheduleTime / ComponentSchedule.Time

extension Components.Schemas.ScheduleTime {
    init(_ model: StudyDefinition.ComponentSchedule.Time) {
        self.init(
            hour: model.hour,
            minute: model.minute == 0 ? nil : model.minute,
            second: model.second == 0 ? nil : model.second
        )
    }
}

extension StudyDefinition.ComponentSchedule.Time {
    init(_ schema: Components.Schemas.ScheduleTime) {
        self.init(
            hour: schema.hour,
            minute: schema.minute ?? 0,
            second: schema.second ?? 0
        )
    }
}

// MARK: - DateComponents

extension Components.Schemas.DateComponents {
    init(_ model: Foundation.DateComponents) {
        self.init(year: model.year, month: model.month, day: model.day)
    }
}

extension Foundation.DateComponents {
    init(_ schema: Components.Schemas.DateComponents) {
        self.init()
        self.year = schema.year
        self.month = schema.month
        self.day = schema.day
    }
}


// MARK: - Weekday

extension Components.Schemas.WeeklyRepetition.WeekdayPayload {
    init(_ model: Locale.Weekday) throws {
        switch model {
        case .monday: self = .monday
        case .tuesday: self = .tuesday
        case .wednesday: self = .wednesday
        case .thursday: self = .thursday
        case .friday: self = .friday
        case .saturday: self = .saturday
        case .sunday: self = .sunday
        @unknown default:
            throw ServerError.internalServerError("Unknown weekday: \(model)")
        }
    }
}

extension Locale.Weekday {
    init(_ schema: Components.Schemas.WeeklyRepetition.WeekdayPayload) {
        switch schema {
        case .monday: self = .monday
        case .tuesday: self = .tuesday
        case .wednesday: self = .wednesday
        case .thursday: self = .thursday
        case .friday: self = .friday
        case .saturday: self = .saturday
        case .sunday: self = .sunday
        }
    }
}
