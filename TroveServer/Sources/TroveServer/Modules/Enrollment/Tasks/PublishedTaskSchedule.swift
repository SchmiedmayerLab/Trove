//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveStudyDefinition


struct PublishedTaskPlan: Codable, Sendable {
    let schedules: [PublishedTaskSchedule]

    /// The Gregorian calendar of the study's enrollment-period time zone, with fixed week rules.
    static func calendar(timeZone: String) throws -> Calendar {
        guard let zone = TimeZone(identifier: timeZone) else { throw ServerError.unexpectedError }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.firstWeekday = 1
        calendar.minimumDaysInFirstWeek = 1
        return calendar
    }

    func validate(timeZone: String) throws {
        let calendar = try Self.calendar(timeZone: timeZone)
        for plan in schedules {
            try PublishedTaskSchedule.validate(plan.schedule.scheduleDefinition, scheduleID: plan.schedule.id, calendar: calendar)
        }
    }
}


struct PublishedTaskSchedule: Codable, Sendable {
    let schedule: StudyDefinition.ComponentSchedule
    let questionnaireSHA256: String
    /// The base language of the published Questionnaire.
    let language: String
    /// The languages the publication approved for administration.
    let administrationLanguages: [String]
    /// The published Questionnaire's `url` and `version`, joined by a vertical bar.
    let questionnaireCanonical: String

    init(
        schedule: StudyDefinition.ComponentSchedule,
        questionnaireSHA256: String,
        language: String,
        administrationLanguages: [String],
        questionnaireCanonical: String
    ) {
        self.schedule = schedule
        self.questionnaireSHA256 = questionnaireSHA256
        self.language = language
        self.administrationLanguages = administrationLanguages
        self.questionnaireCanonical = questionnaireCanonical
    }

    /// Publication validates each Questionnaire against the Grove profile, which requires `url` and `version`.
    init(schedule: StudyDefinition.ComponentSchedule, instrument: PublishedInstrument, questionnaire: Data) throws {
        guard let resource = try? JSONSerialization.jsonObject(with: questionnaire) as? [String: Any],
              let url = resource["url"] as? String, let version = resource["version"] as? String, !url.isEmpty, !version.isEmpty else {
            throw ServerError.internalServerError("A published Questionnaire has no canonical URL and version")
        }
        self.init(
            schedule: schedule,
            questionnaireSHA256: instrument.sha256,
            language: instrument.language,
            administrationLanguages: instrument.administrationLanguages.map(\.language),
            questionnaireCanonical: "\(url)|\(version)"
        )
    }

    static func absoluteDate(_ parts: DateComponents, scheduleID: UUID, calendar: Calendar) throws -> Date {
        guard parts.year != nil, parts.month != nil, parts.day != nil, parts.isValidDate(in: calendar),
              let date = calendar.date(from: parts) else {
            throw ServerError(
                status: .unprocessableContent,
                title: "Invalid task schedule",
                detail: "Schedule \(scheduleID.uuidString.lowercased()) requires a valid year, month and day"
            )
        }
        return date
    }

    static func validate(_ definition: StudyDefinition.ComponentSchedule.ScheduleDefinition, scheduleID: UUID, calendar: Calendar) throws {
        let valid: Bool
        switch definition {
        case .once(.date(let parts)):
            _ = try absoluteDate(parts, scheduleID: scheduleID, calendar: calendar)
            return
        case let .once(.event(_, offset, time)):
            valid = (-3_652_058...3_652_058).contains(offset)
                && (time.map { TaskRecurrence.validTime(hour: $0.hour, minute: $0.minute, second: $0.second) } ?? true)
        case let .repeated(pattern, offset):
            valid = recurrence(pattern).isValid && (0...9998).contains(offset.year ?? 0)
                && (0...119_988).contains(offset.month ?? 0) && (0...3_652_058).contains(offset.day ?? 0)
        }
        guard valid else {
            throw ServerError(
                status: .unprocessableContent,
                title: "Invalid task schedule",
                detail: "Schedule \(scheduleID.uuidString.lowercased()) has an invalid recurrence, time or offset"
            )
        }
    }

    private static func recurrence(_ pattern: StudyDefinition.ComponentSchedule.ScheduleDefinition.RepetitionPattern) -> TaskRecurrence {
        switch pattern {
        case let .daily(interval, hour, minute, second):
            return .init(frequency: .daily, interval: interval, hour: hour, minute: minute, second: second)
        case let .weekly(interval, weekday, hour, minute, second):
            let weekdays: [Locale.Weekday] = [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]
            let index = weekday.flatMap { weekdays.firstIndex(of: $0) }.map { $0 + 1 }
            return .init(frequency: .weekly(weekday: index), interval: interval, hour: hour, minute: minute, second: second)
        case let .monthly(interval, day, hour, minute, second):
            return .init(frequency: .monthly(day: day), interval: interval, hour: hour, minute: minute, second: second)
        }
    }

    func eligibleFrom(enrolledAt: Date, acceptedAt: Date, firstAdoption: Bool) -> Date {
        if firstAdoption, case .once(.event(.enrollment, _, _)) = schedule.scheduleDefinition {
            return enrolledAt
        }
        return acceptedAt
    }

    /// The due instant of a one-time schedule, or `nil` for a repeated schedule or one that never becomes due.
    ///
    /// A date resolves in `calendar`, the study's enrollment-period time zone. An enrollment-relative time that does not
    /// exist on its day advances to the first valid time, and yields no occurrence when that time falls on the next day.
    func oneTimeDue(enrolledAt: Date, calendar: Calendar) throws -> Date? {
        guard case .once(let rule) = schedule.scheduleDefinition else {
            return nil
        }
        switch rule {
        case .date(let parts):
            return try Self.absoluteDate(parts, scheduleID: schedule.id, calendar: calendar)
        case let .event(event, offset, time):
            guard case .enrollment = event else {
                return nil
            }
            guard let day = calendar.date(byAdding: .day, value: offset, to: enrolledAt) else { throw TaskRecurrence.InvalidSchedule() }
            guard let time else {
                return day
            }
            guard let due = calendar.date(
                bySettingHour: time.hour,
                minute: time.minute,
                second: time.second,
                of: day,
                matchingPolicy: .nextTime,
                repeatedTimePolicy: .first,
                direction: .forward
            ) else { throw TaskRecurrence.InvalidSchedule() }
            return calendar.isDate(due, inSameDayAs: day) ? due : nil
        }
    }

    func dates(enrolledAt: Date, from start: Date, until end: Date, calendar: Calendar) throws -> [Date] {
        switch schedule.scheduleDefinition {
        case .once:
            guard let due = try oneTimeDue(enrolledAt: enrolledAt, calendar: calendar) else {
                return []
            }
            return (start..<end).contains(due) ? [due] : []
        case let .repeated(pattern, offset):
            guard let anchor = calendar.date(byAdding: offset, to: enrolledAt) else { throw TaskRecurrence.InvalidSchedule() }
            return try Self.recurrence(pattern).dates(anchor: anchor, from: start, until: end, calendar: calendar)
        }
    }
}
