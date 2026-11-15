//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import ModelsR4
import Testing
@testable import TroveServer


struct StudyPointProjectionTests {
    @Test
    func derivedViewPreservesExactNumbersNativeUUIDAndWriterFacts() throws {
        let event = try StudyProjectionFixture.event()
        let original = event.rawBytes
        let result = try StudyPointProjection.project(event, outputs: Set(event.outputs.map(\.fullURL)), subject: StudyProjectionFixture.subject())
        let text = String(decoding: result.json, as: UTF8.self)
        #expect(text.contains(StudyProjectionFixture.decimal))
        #expect(text.contains(NativeIdentifierFixture.uuid))
        #expect(text.contains(StudyProjectionFixture.writerVersion))
        #expect(text.contains(StudyProjectionFixture.writerValue))
        #expect(!text.contains("UNFILTERED-NARRATIVE"))
        let observation = try #require(StudyProjectionFixture.resources(result, type: "Observation").first)
        let note = try #require((observation["note"] as? [[String: Any]])?.first)
        #expect(note["text"] as? String == StudyProjectionFixture.note)
        let subject = try #require(observation["subject"] as? [String: Any])
        #expect((subject["identifier"] as? [String: Any])?["value"] as? String == "enrollment-a")
        #expect(event.rawBytes == original)
        #expect(result.policy == "study-point-view-v1")
        _ = try JSONDecoder().decode(ModelsR4.Bundle.self, from: result.json)
        #expect(throws: (any Error).self) { try ExchangeRecord(validating: result.json) }
        try Self.expectClosedReferences(result)
    }

    @Test
    func excludesOtherOutputsAndTheirSupportingDevices() throws {
        let event = try StudyProjectionFixture.event(additionalOutput: true)
        try #require(event.outputs.count == 2)
        let first = try #require(event.outputs.first)
        let result = try StudyPointProjection.project(event, outputs: [first.fullURL], subject: StudyProjectionFixture.subject())
        let text = String(decoding: result.json, as: UTF8.self)
        #expect(!text.contains("UNSELECTED-OUTPUT"))
        #expect(!text.contains("UNSELECTED-DEVICE"))
        #expect(try StudyProjectionFixture.resources(result, type: "Observation").count == 1)
        let provenance = try #require(StudyProjectionFixture.resources(result, type: "Provenance").first)
        #expect((provenance["target"] as? [Any])?.count == 1)
        #expect(result.entries.contains { $0.originalFullURL == first.fullURL })
        #expect(!result.entries.contains { $0.originalFullURL == event.outputs[1].fullURL })
        try Self.expectClosedReferences(result)
    }

    @Test
    func questionnaireAndParticipationContextCannotRideAlongWithAPointGrant() throws {
        let event = try StudyProjectionFixture.event(healthKit: false)
        let result = try StudyPointProjection.project(event, outputs: Set(event.outputs.map(\.fullURL)), subject: StudyProjectionFixture.subject())
        for type in ["Patient", "QuestionnaireResponse", "ResearchSubject", "ResearchStudy", "PlanDefinition"] {
            #expect(try StudyProjectionFixture.resources(result, type: type).isEmpty)
        }
        let observation = try #require(StudyProjectionFixture.resources(result, type: "Observation").first)
        let dependency = try #require((observation["derivedFrom"] as? [[String: Any]])?.first)
        #expect(dependency["reference"] == nil)
        #expect(dependency["type"] as? String == "QuestionnaireResponse")
        let identifier = try #require(dependency["identifier"] as? [String: String])
        let context = try #require(event.questionnaireContexts.first)
        #expect(identifier == ["system": context.identifier.system, "value": context.identifier.value])
        let text = String(decoding: result.json, as: UTF8.self)
        #expect(!text.contains("workflow-researchStudy"))
        #expect(!text.contains("participant-001"))
        try Self.expectClosedReferences(result)
    }

    @Test
    func derivedIdentityNeverReusesTheOriginalImmutableRepresentation() throws {
        let event = try StudyProjectionFixture.event()
        let selected = Set(event.outputs.map(\.fullURL))
        let first = try StudyPointProjection.project(event, outputs: selected, subject: StudyProjectionFixture.subject())
        let second = try StudyPointProjection.project(event, outputs: selected, subject: StudyProjectionFixture.subject("enrollment-b"))
        let record = try ExchangeRecord(validating: event.rawBytes)
        #expect(first.id != second.id)
        #expect(first.sourceVersion == record.version.identifier.identifier)
        #expect(first.sourceRecord == record.sourceRecord)
        #expect(first.entries.allSatisfy { $0.derivedFullURL != $0.originalFullURL && !$0.sourceProfiles.isEmpty })
        for view in [first, second] {
            let text = String(decoding: view.json, as: UTF8.self)
            #expect(!text.contains(record.version.identifier.identifier.value))
            #expect(!text.contains("grove-exchange-entry-key"))
            #expect(!text.contains("device-snapshot"))
            #expect(text.contains(NativeIdentifierFixture.uuid))
            #expect(text.contains(event.outputs[0].sourceOutputIdentifier.value))
            for entry in try StudyProjectionFixture.entries(view) {
                #expect(entry["extension"] == nil)
                let resource = try #require(entry["resource"] as? [String: Any])
                let meta = try #require(resource["meta"] as? [String: Any])
                #expect(meta["profile"] == nil)
                #expect((meta["tag"] as? [[String: String]])?.contains { $0["code"] == "SUBSETTED" } == true)
            }
        }
        #expect(String(decoding: second.json, as: UTF8.self).contains("enrollment-b"))
        #expect(!String(decoding: second.json, as: UTF8.self).contains("enrollment-a"))
    }

    @Test
    func emptyUnknownAndSupportingResourceSelectionsFailWithoutReturningAPartialView() throws {
        let event = try StudyProjectionFixture.event()
        let device = try #require(event.nodes.first { $0.resourceType == "Device" }).fullURL
        for selected: Set<String> in [[], ["urn:unavailable"], [device], [event.outputs[0].fullURL, device]] {
            #expect {
                try StudyPointProjection.project(event, outputs: selected, subject: StudyProjectionFixture.subject())
            } throws: {
                let error = $0 as? ServerError
                return error?.status.code == 500 && error?.detail == "Study data projection is unavailable"
            }
        }
    }
}


extension StudyPointProjectionTests {
    private static func expectClosedReferences(_ result: StudyPointProjection.Result) throws {
        let entries = try StudyProjectionFixture.entries(result)
        let addresses = Set(entries.compactMap { $0["fullUrl"] as? String })
        #expect(addresses.count == entries.count)
        #expect(addresses == Set(result.entries.map(\.derivedFullURL)))
        let document = try JSONSerialization.jsonObject(with: result.json)
        #expect(literalReferences(document).isSubset(of: addresses))
        #expect(literalReferences(document).isDisjoint(with: Set(result.entries.map(\.originalFullURL))))
    }

    private static func literalReferences(_ value: Any) -> Set<String> {
        if let object = value as? [String: Any] {
            return object.reduce(into: []) { result, member in
                if member.key == "reference", let value = member.value as? String { result.insert(value) }
                result.formUnion(literalReferences(member.value))
            }
        }
        if let array = value as? [Any] {
            return array.reduce(into: []) { $0.formUnion(literalReferences($1)) }
        }
        return []
    }
}
