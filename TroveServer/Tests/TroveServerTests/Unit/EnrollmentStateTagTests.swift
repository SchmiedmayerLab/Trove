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


struct EnrollmentStateTagTests {
    @Test(arguments: [Int64(1), 2, Int64.max])
    func exactStrongTagRoundTrips(version: Int64) throws {
        let enrollmentID = UUID()
        let tag = EnrollmentStateTag.make(enrollmentID: enrollmentID, version: version)
        #expect(try EnrollmentStateTag.parse(tag, enrollmentID: enrollmentID) == version)
        #expect(throws: ServerError.self) {
            try EnrollmentStateTag.parse(tag, enrollmentID: UUID())
        }
    }

    @Test(arguments: ["", "0", "-1", "+1", "01", "1.0", "1e2", "9223372036854775808", "1\", \"other", "١"])
    func noncanonicalOrUnboundedVersionIsRejected(version: String) {
        let enrollmentID = UUID()
        let tag = "\"enrollment-\(enrollmentID.uuidString)-v\(version)\""
        #expect(throws: ServerError.self) {
            try EnrollmentStateTag.parse(tag, enrollmentID: enrollmentID)
        }
    }
}
