//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPITypes


typealias EnrollmentPeriod = Components.Schemas.EnrollmentPeriod


extension EnrollmentPeriod {
    static var ongoing: Self { .init(calendar: .gregorian, timeZone: "UTC") }

    private static var invalid: ServerError { .badRequest("Invalid enrollment period") }

    func validate() throws {
        guard timeZone.utf8.count <= 128,
              timeZone == "UTC" || TimeZone.knownTimeZoneIdentifiers.contains(timeZone),
              TimeZone(identifier: timeZone) != nil,
              end.map(CollectionMeasurementWindow.valid) ?? true else { throw Self.invalid }
        if let duration {
            guard (0...9998).contains(duration.year ?? 0), (0...119_988).contains(duration.month ?? 0),
                  (0...3_652_058).contains(duration.day ?? 0),
                  [duration.year, duration.month, duration.day].contains(where: { ($0 ?? 0) > 0 }) else { throw Self.invalid }
        }
    }

    /// Resolve once when joining. Refresh, consent adoption and time-zone changes do not renew it.
    func resolve(at enrolledAt: Date) throws -> Date? {
        try validate()
        guard CollectionMeasurementWindow.valid(enrolledAt), let zone = TimeZone(identifier: timeZone) else { throw Self.invalid }
        var bounds = [Date]()
        if let end { bounds.append(end) }
        if let duration {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let offset = DateComponents(year: duration.year, month: duration.month, day: duration.day)
            guard let boundary = calendar.date(byAdding: offset, to: enrolledAt), CollectionMeasurementWindow.valid(boundary) else {
                throw Self.invalid
            }
            bounds.append(boundary)
        }
        guard bounds.allSatisfy({ $0 > enrolledAt }) else { throw ServerError.conflict("The published enrollment period has ended") }
        return bounds.min()
    }
}
