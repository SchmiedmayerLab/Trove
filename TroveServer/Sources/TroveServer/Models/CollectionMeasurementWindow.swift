//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPIServer


typealias CollectionMeasurementWindow = Components.Schemas.CollectionMeasurementWindow


extension CollectionMeasurementWindow {
    static let earliest = Date(timeIntervalSince1970: -62_135_596_800)
    static let latest = Date(timeIntervalSince1970: 253_402_300_799)

    private static var invalid: ServerError { .badRequest("Invalid collection measurement window") }

    static func valid(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite && (earliest...latest).contains(date)
    }

    func validate() throws {
        guard timeZone.utf8.count <= 128,
              timeZone == "UTC" || TimeZone.knownTimeZoneIdentifiers.contains(timeZone),
              TimeZone(identifier: timeZone) != nil,
              end.map(Self.valid) ?? true else { throw Self.invalid }
        switch start {
        case .last(let relative):
            let values = relative.components
            guard (0...9998).contains(values.year ?? 0), (0...119_988).contains(values.month ?? 0),
                  (0...3_652_058).contains(values.day ?? 0),
                  [values.year, values.month, values.day].contains(where: { ($0 ?? 0) > 0 }) else { throw Self.invalid }
        case .absolute(let absolute):
            guard Self.valid(absolute.date), end.map({ $0 > absolute.date }) ?? true else { throw Self.invalid }
        case .oldestSample, .none:
            break
        }
    }

    /// The caller retains this result with acceptance. Never re-evaluate relative dates on reconnect or upload.
    func resolve(at acceptedAt: Date) throws -> ResolvedCollectionWindow {
        try validate()
        guard Self.valid(acceptedAt), let zone = TimeZone(identifier: timeZone) else { throw Self.invalid }
        let lower: Date?
        switch start {
        case .none:
            lower = nil
        case .oldestSample:
            lower = Self.earliest
        case .absolute(let absolute):
            lower = absolute.date
        case .last(let relative):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let values = relative.components
            let offset = DateComponents(year: -(values.year ?? 0), month: -(values.month ?? 0), day: -(values.day ?? 0))
            guard let date = calendar.date(byAdding: offset, to: acceptedAt), Self.valid(date), date < acceptedAt else { throw Self.invalid }
            lower = date
        }
        guard end.map({ $0 > (lower ?? acceptedAt) }) ?? true else { throw Self.invalid }
        return .init(start: lower, end: end)
    }
}
