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


/// Pure assembly tests; authorization, durable audit and HTTP disclosure are separate obligations.
struct StudyPointExportTests {
    @Test
    func exportCarriesItsOwnHistoricalStudyContextAndDerivationProvenance() throws {
        let event = try StudyProjectionFixture.event(healthKit: false)
        let grant = try Self.grant(output: event.outputs[0].fullURL)
        let result = try StudyPointExport.build(event, grants: [grant], context: Self.context())
        let bundle = try JSONDecoder().decode(ModelsR4.Bundle.self, from: result.json)
        #expect(bundle.identifier?.value?.value?.string == result.id.uuidString.lowercased())
        #expect(bundle.identifier?.system?.value?.url.absoluteString == "https://trove.example/exports")
        #expect(try Self.resources(result, type: "PlanDefinition").map { $0["version"] as? String } == ["1"])
        #expect(try Self.resources(result, type: "ResearchStudy").count == 1)
        #expect(try Self.resources(result, type: "ResearchSubject").count == 1)
        let provenance = try Self.resources(result, type: "Provenance")
        #expect(provenance.count == 2, "Keep conversion facts and record the receiver's derivation separately.")
        let derived = try #require(provenance.first { $0["policy"] != nil })
        #expect(derived["policy"] as? [String] == ["urn:trove:study-point-view-v1"])
        let source = try #require((derived["entity"] as? [[String: Any]])?.first?["what"] as? [String: Any])
        #expect(source["identifier"] as? [String: String] == ["system": "https://trove.example/study-grants", "value": grant.id.uuidString.lowercased()])
        #expect(!String(decoding: result.json, as: UTF8.self).contains("participant-001"))
        #expect(!String(decoding: result.json, as: UTF8.self).contains("other-study.example"))
        #expect(!String(decoding: result.json, as: UTF8.self).contains("OTHER-STUDY"))
        for entry in try Self.entries(result) {
            let resource = try #require(entry["resource"] as? [String: Any])
            if ["Observation", "Device"].contains(resource["resourceType"] as? String ?? "") {
                let meta = try #require(resource["meta"] as? [String: Any])
                #expect((meta["security"] as? [[String: String]])?.first?["code"] == "R")
            }
        }
        #expect(String(decoding: result.json, as: UTF8.self).contains(StudyProjectionFixture.decimal))
        #expect(throws: (any Error).self) { try ExchangeRecord(validating: result.json) }
        try Self.expectClosedReferences(result)
    }

    @Test
    func overlappingHistoricalRevisionsDoNotDuplicateTheOutput() throws {
        let event = try StudyProjectionFixture.event()
        let first = try Self.grant(output: event.outputs[0].fullURL, revision: "1")
        let second = try Self.grant(output: event.outputs[0].fullURL, revision: "3")
        let result = try StudyPointExport.build(event, grants: [first, second], context: Self.context())
        #expect(try Self.resources(result, type: "Observation").count == 1)
        #expect(try Set(Self.resources(result, type: "PlanDefinition").compactMap { $0["version"] as? String }) == ["1", "3"])
        #expect(try Self.resources(result, type: "ResearchStudy").count == 2)
        let point = try #require(Self.resources(result, type: "Observation").first)
        let extensions = try #require(point["extension"] as? [[String: Any]])
        #expect(extensions.filter { $0["url"] as? String == "http://hl7.org/fhir/StructureDefinition/workflow-researchStudy" }.count == 2)
        try Self.expectClosedReferences(result)
    }

    @Test
    func eachOutputNamesOnlyItsExactGrantedProtocolRevision() throws {
        let event = try StudyProjectionFixture.event(additionalOutput: true)
        let grants = try [Self.grant(output: event.outputs[0].fullURL, revision: "1"), Self.grant(output: event.outputs[1].fullURL, revision: "2")]
        let result = try StudyPointExport.build(event, grants: grants, context: Self.context())
        let entries = try Self.entries(result)
        let resources = try Dictionary(uniqueKeysWithValues: entries.map {
            (try #require($0["fullUrl"] as? String), try #require($0["resource"] as? [String: Any]))
        })
        for grant in grants {
            let address = try #require(result.sourceEntries.first { $0.originalFullURL == grant.outputFullURL }).derivedFullURL
            let observation = try #require(resources[address])
            let extensions = try #require(observation["extension"] as? [[String: Any]])
            let association = try #require(extensions.first { $0["url"] as? String == "http://hl7.org/fhir/StructureDefinition/workflow-researchStudy" })
            let studyURL = try #require((association["valueReference"] as? [String: Any])?["reference"] as? String)
            let study = try #require(resources[studyURL])
            let protocolURL = try #require((study["protocol"] as? [[String: Any]])?.first?["reference"] as? String)
            #expect(resources[protocolURL]?["version"] as? String == grant.enrollment.protocolVersion)
        }
        try Self.expectClosedReferences(result)
    }

    @Test
    func endedEnrollmentRetainsItsEligibleHistoryWithAnAccurateStatus() throws {
        let event = try StudyProjectionFixture.event()
        var context = try Self.context()
        context.enrollmentEndsAt = context.recordedAt.addingTimeInterval(-1)
        let result = try StudyPointExport.build(event, grants: [Self.grant(output: event.outputs[0].fullURL)], context: context)
        let enrollment = try #require(Self.resources(result, type: "ResearchSubject").first)
        #expect(enrollment["status"] as? String == "off-study")
        let end = try #require(context.enrollmentEndsAt)
        #expect((enrollment["period"] as? [String: String])?["end"] == StudyPointExport.timestamp(end))
        #expect(try Self.resources(result, type: "Observation").count == 1)
    }

    @Test
    func mixedStudyOrEnrollmentAndDuplicateGrantClaimsAreRejected() throws {
        let event = try StudyProjectionFixture.event()
        let first = try Self.grant(output: event.outputs[0].fullURL)
        let otherStudy = try Self.grant(output: event.outputs[0].fullURL, study: "study-b")
        let otherEnrollment = try Self.grant(output: event.outputs[0].fullURL, enrollment: "enrollment-b")
        let unknown = try Self.grant(output: "urn:unavailable")
        for grants in [[], [first, first], [first, otherStudy], [first, otherEnrollment], [unknown]] {
            #expect { try StudyPointExport.build(event, grants: grants, context: Self.context()) } throws: {
                let error = $0 as? ServerError
                return error?.status.code == 500 && error?.detail == "Study data export is unavailable"
            }
        }
    }

    @Test
    func boundsProduceAnExplicitCapacityFailureInsteadOfDroppingLineage() throws {
        let event = try StudyProjectionFixture.event()
        let grant = try Self.grant(output: event.outputs[0].fullURL)
        #expect(throws: StudyProjectionJSON.Failure.outputTooLarge) {
            try StudyPointExport.build(event, grants: Array(repeating: grant, count: 8193), context: Self.context())
        }
        let oversized = try StudyProjectionJSON.string(String(repeating: "x", count: 16 * 1024 * 1024))
        #expect(throws: StudyProjectionJSON.Failure.outputTooLarge) { try oversized.encoded() }
        let boundary = try StudyProjectionJSON.string(String(repeating: "x", count: 16 * 1024 * 1024 - 2))
        #expect(try boundary.encoded().count == 16 * 1024 * 1024)
        #expect(throws: StudyProjectionJSON.Failure.outputTooLarge) { try StudyProjectionJSON.array([boundary]).encoded() }
        #expect(throws: StudyProjectionJSON.Failure.outputTooLarge) { try StudyProjectionJSON.object(["value": boundary]).encoded() }
    }
}


extension StudyPointExportTests {
    private static func context() throws -> StudyPointExport.Context {
        try .init(
            subject: StudyProjectionFixture.subject(),
            exportSystem: IdentifierSystem("https://trove.example/exports"),
            grantSystem: IdentifierSystem("https://trove.example/study-grants"),
            receiver: BusinessIdentifier(system: IdentifierSystem("https://trove.example/services"), value: "study-export"),
            recordedAt: Date(timeIntervalSince1970: 1_800_000_000),
            enrollmentEndsAt: nil
        )
    }

    private static func grant(
        output: String, revision: String = "1", study: String = "study-a", enrollment: String = "enrollment-a"
    ) throws -> StudyPointExport.Grant {
        try .init(id: UUID(), outputFullURL: output, enrollment: StudyEnrollment(
            study: BusinessIdentifier(system: IdentifierSystem("https://trove.example/studies"), value: study),
            protocolURL: FHIRPrimitive(Canonical(stringLiteral: "https://trove.example/PlanDefinition/" + study)),
            protocolVersion: revision,
            enrollment: BusinessIdentifier(system: IdentifierSystem("https://trove.example/enrollments"), value: enrollment)
        ))
    }

    private static func entries(_ result: StudyPointExport.Result) throws -> [[String: Any]] {
        let bundle = try #require(JSONSerialization.jsonObject(with: result.json) as? [String: Any])
        return try #require(bundle["entry"] as? [[String: Any]])
    }

    private static func resources(_ result: StudyPointExport.Result, type: String) throws -> [[String: Any]] {
        try entries(result).compactMap { $0["resource"] as? [String: Any] }.filter { $0["resourceType"] as? String == type }
    }

    private static func expectClosedReferences(_ result: StudyPointExport.Result) throws {
        let entries = try entries(result)
        let addresses = Set(entries.compactMap { $0["fullUrl"] as? String })
        #expect(addresses.count == entries.count)
        #expect(literalReferences(try JSONSerialization.jsonObject(with: result.json)).isSubset(of: addresses))
        #expect(Set(result.sourceEntries.map(\.derivedFullURL)).isSubset(of: addresses))
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
