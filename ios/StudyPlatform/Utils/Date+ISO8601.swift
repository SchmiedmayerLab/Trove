//
// This source file is part of the StudyPlatform-iOS open source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation

extension Date {
    static let iso8601DateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var iso8601DateString: String { Self.iso8601DateFormatter.string(from: self) }

    init?(iso8601DateString: String) {
        guard let date = Self.iso8601DateFormatter.date(from: iso8601DateString) else { return nil }
        self = date
    }
}
