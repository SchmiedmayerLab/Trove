//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import Testing
import TroveAPITypes


struct ExchangeRecordBytesTests {
    @Test
    func restoresStagedOrderWithoutChangingTokensOrVersion() throws {
        let original = try Self.record(note: "nested {\"value\": [1]} and slash \\ and quote \"")
        let originalBytes = try ExchangeRecordBytes(original)
        let reversed = try originalBytes.restoring(entryFullURLs: Array(originalBytes.entryFullURLs.reversed()))
        #expect(reversed.json != original.json)
        #expect(reversed.version == original.version)
        let restored = try ExchangeRecordBytes(reversed).restoring(entryFullURLs: originalBytes.entryFullURLs)
        #expect(restored.json == original.json)
    }

    @Test
    func missingDuplicateAndUnknownEntriesCannotFormAReceiptCommitment() throws {
        let bytes = try ExchangeRecordBytes(Self.record())
        let first = try #require(bytes.entryFullURLs.first)
        #expect(throws: (any Error).self) { try bytes.restoring(entryFullURLs: []) }
        #expect(throws: (any Error).self) { try bytes.restoring(entryFullURLs: [first, first]) }
        #expect(throws: (any Error).self) { try bytes.restoring(entryFullURLs: ["urn:unknown"]) }
        #expect(throws: (any Error).self) { try bytes.restoring(entryFullURLs: [first]) }
    }
}


extension ExchangeRecordBytesTests {
    private static func record(note: String? = nil) throws -> ExchangeRecord {
        try RecordFixture.make(sourceID: DeliveryFixture.sourceID, registrationID: UUID(), seed: "entry-order", note: note)
    }
}
