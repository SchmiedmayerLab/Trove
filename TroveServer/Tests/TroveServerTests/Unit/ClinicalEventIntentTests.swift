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


struct ClinicalEventIntentTests {
    @Test
    func normalizedIntentHasOnePortableByteRepresentation() throws {
        let id = try #require(UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"))
        let intent = try ClinicalEventIntent(targets: [.init(consentID: id, outputFullURLs: ["urn:output:b", "urn:output:a"])])
        #expect(intent.serialized == #"[{"consentId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","outputFullUrls":["urn:output:a","urn:output:b"]}]"#)
        let reversed = try ClinicalEventIntent(targets: [.init(consentID: id, outputFullURLs: ["urn:output:a", "urn:output:b"])])
        #expect(intent.sha256 == reversed.sha256)
        let changed = try ClinicalEventIntent(targets: [.init(consentID: id, outputFullURLs: ["urn:output:a"])])
        #expect(intent.sha256 != changed.sha256)
    }

    @Test(arguments: [[], [""], ["urn:a", "urn:a"], ["urn:é"], ["urn:a\n"], [String(repeating: "a", count: 513)]])
    func invalidOutputSetsAreRejected(outputs: [String]) throws {
        #expect(throws: ServerError.self) {
            try ClinicalEventIntent(targets: [.init(consentID: UUID(), outputFullURLs: outputs)])
        }
    }

    @Test(arguments: [17])
    func boundedConsentCountIsRequired(count: Int) throws {
        let targets = (0..<count).map { _ in ClinicalEventTarget(consentID: UUID(), outputFullURLs: ["urn:output:a"]) }
        #expect(throws: ServerError.self) { try ClinicalEventIntent(targets: targets) }
    }

    @Test
    func repeatedConsentCannotSplitIntoMultipleTargets() throws {
        let id = UUID()
        #expect(throws: ServerError.self) {
            try ClinicalEventIntent(targets: [
                .init(consentID: id, outputFullURLs: ["urn:a"]), .init(consentID: id, outputFullURLs: ["urn:b"])
            ])
        }
    }
}
