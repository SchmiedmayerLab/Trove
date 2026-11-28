//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPITypes


extension TaskOccurrenceStore {
    /// How many days ahead, from the start of today in the enrollment time zone, occurrences are assigned.
    static let assignmentHorizonDays = 60

    /// Projections keep the wire's microsecond precision, so a stored occurrence equals the one the API returns.
    static func encode(_ item: Item) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(TroveDateTranscoder().encode(date))
        }
        return String(decoding: try encoder.encode(item), as: UTF8.self)
    }

    static func decode(_ projection: String) throws -> Item {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { try TroveDateTranscoder().decode($0.singleValueContainer().decode(String.self)) }
        return try decoder.decode(Item.self, from: Data(projection.utf8))
    }

    /// A date at the wire's microsecond precision, as the API and the database return it.
    static func microseconds(_ date: Date) throws -> Date {
        try TroveDateTranscoder().decode(TroveDateTranscoder().encode(date))
    }
}


extension Date {
    /// The start of this instant's whole second.
    var flooredToSecond: Date {
        Date(timeIntervalSinceReferenceDate: timeIntervalSinceReferenceDate.rounded(.down))
    }
}
