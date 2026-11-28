//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// Matching uses local calendar days. A gap advances to the first valid time and a fold uses its first instant.
/// Weekly intervals count Sunday-to-Saturday weeks from the week that contains the anchor.
struct TaskRecurrence {
    struct InvalidSchedule: Error {}

    enum Frequency {
        case daily
        case weekly(weekday: Int?)
        case monthly(day: Int?)
    }

    let frequency: Frequency
    let interval: Int
    let hour: Int
    let minute: Int
    let second: Int

    var isValid: Bool {
        guard interval > 0, Self.validTime(hour: hour, minute: minute, second: second) else {
            return false
        }
        switch frequency {
        case .daily: return true
        case .weekly(let weekday): return weekday.map((1...7).contains) ?? true
        case .monthly(let day): return day.map((1...31).contains) ?? true
        }
    }

    static func dayBoundary(after days: Int, from date: Date, calendar: Calendar) throws -> Date {
        guard let shifted = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: date)) else {
            throw InvalidSchedule()
        }
        return calendar.startOfDay(for: shifted)
    }

    static func validTime(hour: Int, minute: Int, second: Int) -> Bool {
        (0..<24).contains(hour) && (0..<60).contains(minute) && (0..<60).contains(second)
    }

    func dates(anchor: Date, from lower: Date, until upper: Date, calendar: Calendar) throws -> [Date] {
        guard isValid else { throw InvalidSchedule() }
        let first = calendar.startOfDay(for: anchor)
        guard let firstOrdinal = calendar.ordinality(of: .day, in: .era, for: first) else { throw InvalidSchedule() }
        var day = calendar.startOfDay(for: max(anchor, lower))
        var dates = [Date]()
        while day < upper {
            guard let ordinal = calendar.ordinality(of: .day, in: .era, for: day) else { throw InvalidSchedule() }
            let days = ordinal - firstOrdinal
            if matches(day: day, days: days, anchor: first, calendar: calendar),
                let date = calendar.date(
                    bySettingHour: hour,
                    minute: minute,
                    second: second,
                    of: day,
                    matchingPolicy: .nextTime,
                    repeatedTimePolicy: .first,
                    direction: .forward
                ),
                calendar.isDate(date, inSameDayAs: day), date >= max(anchor, lower), date < upper {
                dates.append(date)
            }
            day = try Self.dayBoundary(after: 1, from: day, calendar: calendar)
        }
        return dates
    }

    private func matches(day: Date, days: Int, anchor: Date, calendar: Calendar) -> Bool {
        switch frequency {
        case .daily:
            return days.isMultiple(of: interval)
        case .weekly(let weekday):
            // Weeks start on Sunday (weekday 1), independent of the calendar's locale settings.
            let anchorWeekday = calendar.component(.weekday, from: anchor)
            let offsetInWeek = anchorWeekday - 1
            return ((days + offsetInWeek) / 7).isMultiple(of: interval)
                && calendar.component(.weekday, from: day) == (weekday ?? anchorWeekday)
        case .monthly(let target):
            let months =
                (calendar.component(.year, from: day) - calendar.component(.year, from: anchor)) * 12
                + calendar.component(.month, from: day) - calendar.component(.month, from: anchor)
            return months.isMultiple(of: interval)
                && calendar.component(.day, from: day) == (target ?? calendar.component(.day, from: anchor))
        }
    }
}
