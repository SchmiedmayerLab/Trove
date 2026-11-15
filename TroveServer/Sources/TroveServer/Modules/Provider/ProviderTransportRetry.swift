//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// Only a retry time crosses the transport boundary, never the provider's diagnostic body or headers.
struct ProviderTransportRetry: Error, Sendable {
    let notBefore: Date

    static func parse(_ value: String?, now: Date = Date()) -> Self {
        guard let value, value.utf8.count <= 128 else {
            return .init(notBefore: now.addingTimeInterval(3600))
        }
        if !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) {
            guard let seconds = UInt64(value), seconds <= 31_536_000 else {
                return .init(notBefore: .distantFuture)
            }
            return .init(notBefore: now.addingTimeInterval(TimeInterval(seconds)))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
        formatter.isLenient = false
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
            return .init(notBefore: now.addingTimeInterval(3600))
        }
        return .init(notBefore: max(now, date))
    }
}
