//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


#if canImport(CryptoKit)
import CryptoKit


#else
import Crypto


#endif


enum TaskOccurrenceID {
    static func make(enrollment: UUID, publication: UUID, schedule: UUID, due: Date) -> String {
        let parts = [enrollment.uuidString, publication.uuidString, schedule.uuidString, String(due.timeIntervalSince1970.bitPattern)]
        return SHA256.hash(data: Data(parts.joined(separator: "/").utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
