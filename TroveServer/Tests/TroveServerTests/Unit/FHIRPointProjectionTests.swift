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
        // Migrated from the earlier simulator capture to the record contract using the pinned IG fixture keyer.
        // This is a fixture migration, not a new simulator capture or official validation result.
        let url = try #require(Foundation.Bundle.module.url(forResource: "HealthKitPointEvent", withExtension: "json"))
        let bytes = try Data(contentsOf: url)
        let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "test-validator")
        #expect(event.rawBytes == bytes)
        #expect(event.nodes.count == 6)
        let point = try #require(event.outputs.first)
        #expect(event.outputs.count == 1)
        #expect(point.value.quantityValue == "73")
        #expect(point.value.quantityCode == "/min")
        #expect(Set(event.deploymentIdentifiers.systems.keys) == [.recordVersion, .sourceRecord, .sourceOutput, .deviceSnapshot])
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
        #expect(event.eventIdentifierSystem == "https://study.example.org/fhir/NamingSystem/grove-record-version-v0/test-key/1")
        let record = try ExchangeRecord(validating: bytes)
        #expect(event.eventIdentifierValue == record.version.identifier.identifier.value)
        #expect(event.nodes.count == 8)
        try #require(event.outputs.count == 1)
        #expect(event.outputs[0].value.quantityValue == "72.0000")
        #expect(event.outputs[0].writerIdentifier == nil)
        #expect(event.outputs[0].writerVersion == nil)
        #expect(event.participants == [.init(system: "https://study.example.org/fhir/identifiers/participant", value: "participant-001")])
    }

    @Test(arguments: ["timestamp", "type"])
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


extension FHIRPointProjectionTests {
    @Test
    func sleepProjectionRetainsCompletePeriodAndNativeCodings() throws {
        // Synthetic graph fixture, not a native capture or official-validator result.
        let bytes = try sleepFixture()
        let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "test-validator")
        let sleep = try #require(event.outputs.first)
        #expect(sleep.profile == Profile.groveMobileSleepStage.value?.url.absoluteString)
        #expect(sleep.effectiveAt == ISO8601DateFormatter().date(from: "2026-08-20T00:00:00Z"))
        #expect(sleep.effectiveEnd == ISO8601DateFormatter().date(from: "2026-08-20T08:00:00Z"))
        #expect(sleep.value == .coded(system: "https://grovealliance.org/fhir/mobile/CodeSystem/grove-sleep-stage", code: "deep"))
        #expect(event.rawBytes == bytes)
        #expect(String(decoding: event.rawBytes, as: UTF8.self).contains("native-stage"))
    }

    @Test(arguments: ["missing-end", "reversed", "date-only", "point", "wrong-value"])
    func sleepProjectionRejectsIncompleteOrIncorrectTemporalShape(corruption: String) throws {
        let bytes = try sleepFixture { observation in
            switch corruption {
            case "missing-end": observation["effectivePeriod"] = ["start": "2026-08-20T00:00:00Z"]
            case "reversed": observation["effectivePeriod"] = ["start": "2026-08-20T08:00:00Z", "end": "2026-08-20T00:00:00Z"]
            case "date-only": observation["effectivePeriod"] = ["start": "2026-08-20", "end": "2026-08-21"]
            case "point":
                observation.removeValue(forKey: "effectivePeriod")
                observation["effectiveDateTime"] = "2026-08-20T00:00:00Z"
            default:
                observation.removeValue(forKey: "valueCodeableConcept")
                observation["valueString"] = "deep"
            }
        }
        #expect { try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "test-validator") }
        throws: { ($0 as? ServerError)?.status.code == 422 }
    }

    private func sleepFixture(_ mutate: (inout [String: Any]) throws -> Void = { _ in }) throws -> Data {
        try changedObservation { observation in
            observation["meta"] = ["profile": ["https://grovealliance.org/fhir/mobile/StructureDefinition/grove-mobile-sleep-stage"]]
            let measurement = ["system": "https://grovealliance.org/fhir/mobile/CodeSystem/grove-mobile-measurement", "code": "sleep-stage"]
            observation["code"] = ["coding": [measurement]]
            observation.removeValue(forKey: "effectiveDateTime")
            observation.removeValue(forKey: "valueQuantity")
            observation["effectivePeriod"] = ["start": "2026-08-20T00:00:00Z", "end": "2026-08-20T08:00:00Z"]
            let stage = ["system": "https://grovealliance.org/fhir/mobile/CodeSystem/grove-sleep-stage", "code": "deep"]
            let native = ["system": "https://fixture.trove.test/native-stage", "code": "4"]
            observation["valueCodeableConcept"] = ["coding": [stage, native]]
            try mutate(&observation)
        }
    }
}
