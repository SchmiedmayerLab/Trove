//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import GroveFHIRContract
import Testing
@testable import TroveServer


struct FHIRClinicalDerivationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TROVE_TEST_LIFECYCLE_CORPUS"] != nil, "Requires the pinned IG corpus"))
    func pinnedPendingAndTargetKeepTheirReferenceSemantics() throws {
        let path = try #require(ProcessInfo.processInfo.environment["TROVE_TEST_LIFECYCLE_CORPUS"])
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let index = try JSONDecoder().decode(
            ReceiverRevisionCorpus.EventIndex.self, from: Data(contentsOf: root.appendingPathComponent("events.json"))
        )
        let events = try ["pending", "target"].map { name in
            let entry = try #require(index.events[name])
            try #require(entry.path == "resources/\(name).json")
            let bytes = try Data(contentsOf: root.appendingPathComponent(entry.path))
            try #require(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == entry.sha256)
            _ = try ExchangeGraph(kind: .active, jsonData: bytes)
            let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "projection-test-only")
            #expect(event.rawBytes == bytes)
            return event
        }
        let pending = try #require(events[0].derivations.first)
        let context = try #require(events[1].questionnaireContexts.first)
        #expect(events[0].questionnaireContexts.isEmpty)
        #expect(pending.target == .logical(context.identifier))
        #expect(events[1].derivations.first?.target == .local(context.fullURL))
    }

    @Test(arguments: [512, 513])
    func derivationCountIsBounded(count: Int) throws {
        var event = try FHIRPointProjection.project(validatedBytes: fixture(), validatorIdentity: "test-only")
        let derivation = try #require(event.derivations.first)
        event.derivations = Array(repeating: derivation, count: count)
        if count == 512 {
            try ClinicalGraphStore.validate(event)
        } else {
            #expect {
                try ClinicalGraphStore.validate(event)
            } throws: { ($0 as? ServerError)?.status.code == 400 }
        }
    }

    @Test
    func literalDerivationRetainsExactContextEntry() throws {
        let event = try FHIRPointProjection.project(validatedBytes: fixture(), validatorIdentity: "test-only")
        let context = try #require(event.questionnaireContexts.first)
        #expect(event.questionnaireContexts.count == 1)
        #expect(event.derivations.count == 1)
        #expect(event.derivations[0].target == .local(context.fullURL))
        #expect(event.derivations[0].outputFullURL == event.outputs[0].fullURL)
    }

    @Test
    func missingLogicalContextPreservesItsCompleteIdentity() throws {
        let bytes = try changed { entries, pointIndex, contextIndex in
            var point = try #require(entries[pointIndex]["resource"] as? [String: Any])
            let context = try #require(entries[contextIndex]["resource"] as? [String: Any])
            let identifier = try #require(context["identifier"] as? [String: Any])
            point["derivedFrom"] = [["type": "QuestionnaireResponse", "identifier": identifier]]
            entries[pointIndex]["resource"] = point
            entries.remove(at: contextIndex)
        }
        _ = try ExchangeGraph(kind: .active, jsonData: bytes)
        let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "test-only")
        #expect(event.rawBytes == bytes)
        #expect(event.questionnaireContexts.isEmpty)
        #expect(event.derivations.count == 1)
        guard case .logical(let identifier) = event.derivations[0].target else {
            Issue.record("Logical derivation was replaced with a literal address")
            return
        }
        #expect(identifier.system == "https://study.example.org/fhir/NamingSystem/questionnaire-response")
        #expect(identifier.value == "response-1")
    }

    @Test
    func patientConnectivityDoesNotAuthorizeAnUnrelatedQuestionnaire() throws {
        let bytes = try changed { entries, pointIndex, contextIndex in
            var point = try #require(entries[pointIndex]["resource"] as? [String: Any])
            var context = try #require(entries[contextIndex]["resource"] as? [String: Any])
            context["subject"] = point["subject"]
            point.removeValue(forKey: "derivedFrom")
            entries[pointIndex]["resource"] = point
            entries[contextIndex]["resource"] = context
        }
        _ = try ExchangeGraph(kind: .active, jsonData: bytes)
        #expect {
            try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "test-only")
        } throws: { ($0 as? ServerError)?.status.code == 422 }
    }

    private func fixture() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "ImmutablePointEvent", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func changed(_ mutate: (inout [[String: Any]], Int, Int) throws -> Void) throws -> Data {
        var document = try #require(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        var entries = try #require(document["entry"] as? [[String: Any]])
        let point = try #require(entries.firstIndex { ($0["resource"] as? [String: Any])?["resourceType"] as? String == "Observation" })
        let context = try #require(entries.firstIndex { ($0["resource"] as? [String: Any])?["resourceType"] as? String == "QuestionnaireResponse" })
        try mutate(&entries, point, context)
        document["entry"] = entries
        return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    }
}
