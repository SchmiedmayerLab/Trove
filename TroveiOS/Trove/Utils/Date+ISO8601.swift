//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


extension Date {
    static let iso8601DateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    var iso8601DateString: String { Self.iso8601DateFormatter.string(from: self) }

    init?(iso8601DateString: String) {
        guard let date = Self.iso8601DateFormatter.date(from: iso8601DateString) else {
            return nil
        }
        self = date
    }
}
