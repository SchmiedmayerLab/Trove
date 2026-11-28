//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing


@testable import TroveServer


struct TaskRecurrenceTests {
    private func calendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        return calendar
    }

    @Test
    func identityBindsEnrollmentPublicationScheduleAndInstant() {
        let enrollment = UUID()
        let publication = UUID()
        let schedule = UUID()
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let id = TaskOccurrenceID.make(enrollment: enrollment, publication: publication, schedule: schedule, due: due)
        #expect(TaskOccurrenceID.make(enrollment: enrollment, publication: publication, schedule: schedule, due: due) == id)
        #expect(TaskOccurrenceID.make(enrollment: UUID(), publication: publication, schedule: schedule, due: due) != id)
        #expect(TaskOccurrenceID.make(enrollment: enrollment, publication: UUID(), schedule: schedule, due: due) != id)
        #expect(TaskOccurrenceID.make(enrollment: enrollment, publication: publication, schedule: UUID(), due: due) != id)
        #expect(TaskOccurrenceID.make(enrollment: enrollment, publication: publication, schedule: schedule, due: due.addingTimeInterval(1)) != id)
    }

    @Test
    func fourteenCivilDaysAcrossSpringGap() throws {
        let cal = try calendar()
        let start = try #require(cal.date(from: .init(year: 2026, month: 3, day: 1)))
        let end = try #require(cal.date(byAdding: .day, value: 14, to: start))
        let rule = TaskRecurrence(frequency: .daily, interval: 1, hour: 2, minute: 30, second: 0)
        let dates = try rule.dates(anchor: start, from: start, until: end, calendar: cal)
        #expect(dates.count == 14 && Set(dates).count == 14)
        #expect(cal.component(.hour, from: dates[7]) == 3)
        #expect(cal.component(.hour, from: dates[8]) == 2)
        #expect(try rule.dates(anchor: start, from: dates[4], until: end, calendar: cal) == Array(dates.dropFirst(4)))
    }

    @Test
    func midnightGapKeepsDayBoundariesAndRecurrencePhase() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "America/Santiago"))
        let start = try #require(cal.date(from: .init(year: 2026, month: 9, day: 6, hour: 1)))
        let cutoff = try #require(cal.date(from: .init(year: 2026, month: 9, day: 7, hour: 0)))
        let horizon = try #require(cal.date(from: .init(year: 2026, month: 9, day: 20, hour: 0)))
        #expect(try TaskRecurrence.dayBoundary(after: 1, from: start, calendar: cal) == cutoff)
        #expect(try TaskRecurrence.dayBoundary(after: 14, from: start, calendar: cal) == horizon)
        let rule = TaskRecurrence(frequency: .daily, interval: 2, hour: 9, minute: 0, second: 0)
        let dates = try rule.dates(anchor: start, from: cutoff, until: horizon, calendar: cal)
        #expect(dates.map { cal.component(.day, from: $0) } == [8, 10, 12, 14, 16, 18])
    }

    @Test
    func fallFoldUsesFirstInstant() throws {
        let cal = try calendar()
        let start = try #require(cal.date(from: .init(year: 2026, month: 11, day: 1)))
        let end = try #require(cal.date(byAdding: .day, value: 1, to: start))
        let rule = TaskRecurrence(frequency: .daily, interval: 1, hour: 1, minute: 30, second: 0)
        let dates = try rule.dates(anchor: start, from: start, until: end, calendar: cal)
        #expect(dates == [start.addingTimeInterval(5400)])
    }

    @Test
    func biweeklyMondaysUseTheEnrollmentCalendarWeek() throws {
        let cal = try calendar()
        let anchor = try #require(cal.date(from: .init(year: 2026, month: 11, day: 18)))
        let november = try #require(cal.date(from: .init(year: 2026, month: 11, day: 30, hour: 9)))
        let december = try #require(cal.date(from: .init(year: 2026, month: 12, day: 14, hour: 9)))
        let end = try #require(cal.date(from: .init(year: 2026, month: 12, day: 21)))
        let rule = TaskRecurrence(frequency: .weekly(weekday: 2), interval: 2, hour: 9, minute: 0, second: 0)
        #expect(try rule.dates(anchor: anchor, from: anchor, until: end, calendar: cal) == [november, december])
        #expect(try rule.dates(anchor: anchor, from: november.addingTimeInterval(1), until: end, calendar: cal) == [december])
    }

    /// Weeks start on Sunday whatever the calendar's first weekday: a Monday start would select November 22 instead.
    @Test(arguments: [1, 2])
    func biweeklySundaysFromAWednesdayIgnoreTheCalendarWeekStart(firstWeekday: Int) throws {
        var cal = try calendar()
        cal.firstWeekday = firstWeekday
        let anchor = try #require(cal.date(from: .init(year: 2026, month: 11, day: 18)))
        let end = try #require(cal.date(from: .init(year: 2027, month: 1, day: 1)))
        let rule = TaskRecurrence(frequency: .weekly(weekday: 1), interval: 2, hour: 9, minute: 0, second: 0)
        let expected = try [(11, 29), (12, 13), (12, 27)].map { month, day in
            try #require(cal.date(from: .init(year: 2026, month: month, day: day, hour: 9)))
        }
        #expect(try rule.dates(anchor: anchor, from: anchor, until: end, calendar: cal) == expected)
    }

    @Test
    func weeklyAndMonthlyKeepEnrollmentPhase() throws {
        let cal = try calendar()
        let start = try #require(cal.date(from: .init(year: 2026, month: 1, day: 31)))
        let end = try #require(cal.date(byAdding: .month, value: 3, to: start))
        let monthly = TaskRecurrence(frequency: .monthly(day: nil), interval: 1, hour: 9, minute: 0, second: 0)
        let dates = try monthly.dates(anchor: start, from: start, until: end, calendar: cal)
        #expect(dates.map { cal.component(.month, from: $0) } == [1, 3])
        let weekly = TaskRecurrence(frequency: .weekly(weekday: 2), interval: 2, hour: 9, minute: 0, second: 0)
        let weeks = try weekly.dates(anchor: start, from: start, until: end, calendar: cal)
        #expect(weeks.allSatisfy { cal.component(.weekday, from: $0) == 2 })
        #expect(weeks.count == 6)
    }
}
