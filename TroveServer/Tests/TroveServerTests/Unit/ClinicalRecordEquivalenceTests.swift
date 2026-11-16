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
@testable import TroveServer


struct ClinicalRecordEquivalenceTests {
    @Test
    func enrollmentSnapshotMayChangeWithoutChangingTheClinicalVersion() throws {
        let original = try Self.original()
        let updated = try RecordRepresentationFixture.enrollment(original)
        #expect(updated != original)
        #expect(try ExchangeRecord(validating: updated).version == ExchangeRecord(validating: original).version)
        #expect(try ClinicalRecordEquivalence.accepts(updated, asRepresentationOf: original))
        #expect(try ClinicalRecordEquivalence.accepts(original, asRepresentationOf: updated))
        let reusedKey = try RecordRepresentationFixture.enrollment(original, rekey: false)
        #expect(try !ClinicalRecordEquivalence.accepts(reusedKey, asRepresentationOf: original))
    }

    @Test(arguments: ["73", "72.000000000000000000000000000001", "7.2e1", "9007199254740993"])
    func changedClinicalNumberTokensCannotReuseAVersion(value: String) throws {
        let original = try Self.original()
        let string = try #require(String(data: original, encoding: .utf8))
        let modified = Data(string.replacingOccurrences(of: "\"value\":72", with: "\"value\":\(value)").utf8)
        try #require(modified != original)
        #expect(try !ClinicalRecordEquivalence.accepts(modified, asRepresentationOf: original))
    }

    @Test
    func entryOrderAndWhitespaceDoNotChangeClinicalContent() throws {
        let original = try Self.original()
        let entries = try ExchangeRecordBytes(ExchangeRecord(validating: original))
        let reordered = try entries.restoring(entryFullURLs: entries.entryFullURLs.reversed()).json
        #expect(reordered != original)
        #expect(try ClinicalRecordEquivalence.accepts(reordered, asRepresentationOf: original))
        #expect(try ClinicalRecordEquivalence.accepts(original + Data(" ".utf8), asRepresentationOf: original))
    }

    @Test
    func repeatedRetractionRetainsFirstEffectDespiteDifferentReportingTime() throws {
        let original = try Self.original()
        let first = try RetractionEventFixture.bytes(activeBytes: original, sequence: 1)
        let second = try RetractionEventFixture.bytes(activeBytes: original, sequence: 2)
        #expect(first != second)
        #expect(try ClinicalRecordEquivalence.accepts(second, asRepresentationOf: first))
        #expect(try !ClinicalRecordEquivalence.accepts(first, asRepresentationOf: original))
    }
}


extension ClinicalRecordEquivalenceTests {
    private static func original() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "ImmutablePointEvent", withExtension: "json"))
        return try ExchangeRecord(validating: Data(contentsOf: url)).json
    }
}
