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


struct RecordingTransferConfigurationTests {
    @Test
    func defaultsAndIndependentBudgetsAreExplicit() throws {
        let defaults = try RecordingTransferService.Limits(storedBytes: nil, sourceBytes: nil, leaseSeconds: nil)
        #expect(defaults.storedBytes == 128 * 1024 * 1024)
        #expect(defaults.sourceBytes == 512 * 1024 * 1024)
        #expect(defaults.leaseDuration == 900)
        let configured = try RecordingTransferService.Limits(storedBytes: "123", sourceBytes: "456", leaseSeconds: "45")
        #expect(configured.storedBytes == 123 && configured.sourceBytes == 456 && configured.leaseDuration == 45)
    }

    @Test(arguments: ["", "0", "-1", "+1", " 1", "1 ", "1.5", "2147483648", "999999999999999999999999999"])
    func invalidByteBudgetsCannotSilentlyUseDefaults(value: String) {
        #expect(throws: (any Error).self) { try RecordingTransferService.Limits(storedBytes: value, sourceBytes: nil, leaseSeconds: nil) }
        #expect(throws: (any Error).self) { try RecordingTransferService.Limits(storedBytes: nil, sourceBytes: value, leaseSeconds: nil) }
    }

    @Test(arguments: ["0", "3601", "nan", "inf", ""])
    func invalidAttemptLeasesFailConfiguration(value: String) {
        #expect(throws: (any Error).self) { try RecordingTransferService.Limits(storedBytes: nil, sourceBytes: nil, leaseSeconds: value) }
    }
}
