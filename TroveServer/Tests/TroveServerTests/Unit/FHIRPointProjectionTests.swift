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


/// Actual consumer coverage: shared graph rules, lossless projection and receiver limits.
/// Full validator and consent-backed persistence are exercised in their integration lanes.
struct FHIRPointProjectionTests {
    @Test
    func acceptsTheRealHealthKitProducerWithoutDiscardingAcquisitionMetadata() throws {
        // Captured from the owned simulator and independently accepted by the pinned full validator.
        let url = try #require(Foundation.Bundle.module.url(forResource: "HealthKitPointEvent", withExtension: "json"))
        let bytes = try Data(contentsOf: url)
        let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "test-validator")
        #expect(event.rawBytes == bytes)
        #expect(event.nodes.count == 6)
        let point = try #require(event.outputs.first)
        #expect(event.outputs.count == 1)
        #expect(point.quantityValue == "73")
        #expect(point.quantityCode == "/min")
        #expect(Set(event.deploymentIdentifiers.systems.keys) == [.event, .entryNode, .sourceRecord, .sourceOutput, .deviceSnapshot])
    }

    @Test
    func completeIdentifiersUseByteEqualityRatherThanUnicodeEquivalence() {
        let composed = ValidatedExchangeEvent.Identifier(system: "urn:identity", value: "é")
        let decomposed = ValidatedExchangeEvent.Identifier(system: "urn:identity", value: "e\u{301}")
        let otherSystem = ValidatedExchangeEvent.Identifier(system: "URN:identity", value: "é")
        #expect(composed != decomposed)
        #expect(composed != otherSystem)
        #expect(Set([composed, decomposed, otherSystem, composed]).count == 3)
    }

    @Test
    func retainsOriginalBytesAndExactQuantityWhileUsingSharedIdentity() throws {
        let original = try String(decoding: fixture(), as: UTF8.self)
        try #require(original.contains("\"value\": 72,"))
        let bytes = Data((original.replacingOccurrences(of: "\"value\": 72,", with: "\"value\": 72.0000,") + " \n").utf8)
        let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "test-validator")
        #expect(event.rawBytes == bytes)
        #expect(event.validatorIdentity == "test-validator")
        #expect(event.eventIdentifierSystem == "https://study.example.org/fhir/NamingSystem/grove-event-v0")
        #expect(event.eventIdentifierValue == "e0:1f5c58aa-6ec6-4e79-a682-829a9debd3f5:50")
        #expect(event.producerInstance == UUID(uuidString: "1f5c58aa-6ec6-4e79-a682-829a9debd3f5"))
        #expect(event.nodes.count == 8)
        try #require(event.outputs.count == 1)
        #expect(event.outputs[0].quantityValue == "72.0000")
        #expect(event.outputs[0].writerIdentifier == nil)
        #expect(event.outputs[0].writerVersion == nil)
        #expect(event.participants == [.init(system: "https://study.example.org/fhir/identifiers/participant", value: "participant-001")])
    }

    @Test(arguments: ["timestamp", "identifier"])
    func sharedRequiredHeadersCannotBeBypassed(field: String) throws {
        let bytes = try changed { $0.removeValue(forKey: field) }
        #expect {
            try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "test-validator")
        } throws: { ($0 as? ServerError)?.status.code == 422 }
    }

    @Test
    func mismatchedEntryKeyFailsWithSanitizedDiagnostics() throws {
        let bytes = try changed { document in
            var entries = try #require(document["entry"] as? [[String: Any]])
            var extensions = try #require(entries[0]["extension"] as? [[String: Any]])
            var identifier = try #require(extensions[0]["valueIdentifier"] as? [String: Any])
            identifier["value"] = "n0:patient:0:" + String(repeating: "A", count: 43)
            extensions[0]["valueIdentifier"] = identifier
            entries[0]["extension"] = extensions
            document["entry"] = entries
        }
        #expect {
            try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "test-validator")
        } throws: { error in
            let error = error as? ServerError
            return error?.status.code == 422 && error?.detail == "Invalid or unsupported Grove FHIR event"
        }
    }

    @Test
    func validSharedGraphDoesNotEnableUnsupportedReceiverContent() throws {
        let bytes = try changedObservation { observation in
            let author = try #require(observation["subject"] as? [String: Any])
            observation["note"] = [
                ["text": "A note with unsupported author attribution.", "authorReference": author]
            ]
        }
        _ = try ExchangeGraph(validating: bytes, kind: .active)
        #expect {
            try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "test-validator")
        } throws: { ($0 as? ServerError)?.status.code == 422 }
    }

    @Test
    func validWriterEvidencePreservesPrecisionAndOriginalNotes() throws {
        let bytes = try changedObservation { observation in
            var identifiers = try #require(observation["identifier"] as? [[String: Any]])
            let role = ["system": "https://grovealliance.org/fhir/mobile/CodeSystem/grove-identifier-role", "code": "writer-record"]
            identifiers.append([
                "system": "https://study.example.org/fhir/NamingSystem/grove-writer-record-v0/test-key/1",
                "value": "v0:test-key:1:TN39cF6jcCICy4SlWBjpAulk4eMlcb-KM3MwESD9cvw",
                "type": ["coding": [role]]
            ])
            var extensions = try #require(observation["extension"] as? [[String: Any]])
            extensions.append([
                "url": "https://grovealliance.org/fhir/mobile/StructureDefinition/grove-writer-record-version",
                "valueString": "9007199254740992"
            ])
            observation["identifier"] = identifiers
            observation["extension"] = extensions
            observation["note"] = [["text": "Original source wording.", "authorString": "Synthetic author"]]
        }
        _ = try ExchangeGraph(validating: bytes, kind: .active)
        let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "test-validator")
        #expect(event.outputs.first?.writerVersion == "9007199254740992")
        #expect(event.outputs.first?.writerIdentifier?.value == "v0:test-key:1:TN39cF6jcCICy4SlWBjpAulk4eMlcb-KM3MwESD9cvw")
        #expect(event.rawBytes == bytes)
    }
}


extension FHIRPointProjectionTests {
    private func changedObservation(_ mutate: (inout [String: Any]) throws -> Void) throws -> Data {
        try changed { document in
            var entries = try #require(document["entry"] as? [[String: Any]])
            let index = try #require(entries.firstIndex { ($0["resource"] as? [String: Any])?["resourceType"] as? String == "Observation" })
            var observation = try #require(entries[index]["resource"] as? [String: Any])
            try mutate(&observation)
            entries[index]["resource"] = observation
            document["entry"] = entries
        }
    }

    private func fixture() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "ImmutablePointEvent", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func changed(_ mutate: (inout [String: Any]) throws -> Void) throws -> Data {
        var document = try #require(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        try mutate(&document)
        return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    }
}
