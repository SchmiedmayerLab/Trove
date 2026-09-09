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
@testable import TroveServer


struct FHIRRetractionProjectionTests {
    @Test
    func sharedProducerRetractionPreservesBytesAndLogicalTargetsWithoutClinicalPayload() throws {
        let activeBytes = try activeBytes()
        let active = try FHIRPointProjection.project(validatedBytes: activeBytes, validatorIdentity: "test-only")
        let bytes = try RetractionEventFixture.bytes(activeBytes: activeBytes)
        let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "test-only")
        #expect(event.rawBytes == bytes)
        #expect(event.outputs.isEmpty)
        #expect(event.participants.isEmpty)
        #expect(event.nodes.count == 1)
        #expect(event.retraction?.sourceRecordIdentifier == active.outputs[0].sourceRecordIdentifier)
        #expect(event.retraction?.outputIdentifiers == [active.outputs[0].sourceOutputIdentifier])
        #expect(try ClinicalRecordRevision(event).kind == "retraction")
    }

    @Test(arguments: ["extension", "modifierExtension", "location"])
    func unsupportedRetractionSemanticsFailClosed(member: String) throws {
        let bytes = try RetractionEventFixture.bytes(activeBytes: activeBytes())
        var document = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var entries = try #require(document["entry"] as? [[String: Any]])
        var provenance = try #require(entries[0]["resource"] as? [String: Any])
        provenance[member] = member == "location" ? ["reference": "Location/unknown"] : [["url": "urn:unsupported", "valueString": "private-value"]]
        entries[0]["resource"] = provenance
        document["entry"] = entries
        let changed = try JSONSerialization.data(withJSONObject: document)
        #expect {
            try FHIRPointProjection.project(validatedBytes: changed, validatorIdentity: "test-only")
        } throws: { ($0 as? ServerError)?.status.code == 422 }
    }

    private func activeBytes() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "ImmutablePointEvent", withExtension: "json"))
        return try Data(contentsOf: url)
    }
}
