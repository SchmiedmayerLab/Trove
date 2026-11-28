//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import GroveFHIRContract
import Testing
@testable import TroveServer


struct StudyCompanionProjectionTests {
    private static let measurement = "urn:uuid:measurement"
    private static let recording = "urn:uuid:recording"
    private static let roleSystem = Canonicals.root + "/mobile/CodeSystem/grove-identifier-role"

    private static func resource(type: String, value: String) throws -> StudyProjectionJSON {
        try .object([
            "resourceType": .string(type),
            "identifier": .array([
                .object([
                    "system": .string("https://study.example.org/source-output"), "value": .string(value),
                    "type": .object(["coding": .array([.object(["system": .string(roleSystem), "code": .string("source-output")])])])
                ])
            ])
        ])
    }

    private static func projection(grantRecording: Bool) throws -> StudyPointResourceProjection {
        var observation = try #require(resource(type: "Observation", value: "measurement-one").object)
        observation["derivedFrom"] = try .array([
            .object([
                "reference": .string(recording), "display": .string("Raw recording label")
            ])
        ])
        var document = try #require(resource(type: "DocumentReference", value: "recording-one").object)
        document["context"] = try .object(["related": .array([.object(["reference": .string(measurement)])])])
        return try .init(
            resources: [measurement: .object(observation), recording: .object(document)],
            subject: BusinessIdentifier(system: "https://study.example.org/participant", value: "one"),
            outputs: grantRecording ? [measurement, recording] : [measurement],
            recordingURLs: [:],
            receivesDeviceUnitIdentifiers: false
        )
    }

    @Test
    func ungrantedRecordingBecomesOnlyTypedBusinessIdentity() throws {
        let projected = try Self.projection(grantRecording: false).resource(at: Self.measurement)
        let reference = try #require(projected["derivedFrom"]?.array?.first)
        #expect(reference["reference"] == nil)
        #expect(reference["display"] == nil)
        #expect(reference["type"]?.string == "DocumentReference")
        #expect(reference["identifier"]?["value"]?.string == "recording-one")
        #expect(reference["identifier"]?["type"]?["coding"]?.array?.first?["code"]?.string == "source-output")
        #expect(projected["meta"]?["profile"] == nil)
        #expect(projected["meta"]?["tag"]?.array?.first?["code"]?.string == "SUBSETTED")
    }

    @Test
    func independentlyGrantedCompanionKeepsLocalReferencesForRemapping() throws {
        let projection = try Self.projection(grantRecording: true)
        let observation = try projection.resource(at: Self.measurement)
        #expect(observation["derivedFrom"]?.array?.first?["reference"]?.string == Self.recording)
        #expect(observation["derivedFrom"]?.array?.first?["display"] == nil)
        let recording = try projection.resource(at: Self.recording)
        #expect(recording["context"]?["related"]?.array?.first?["reference"]?.string == Self.measurement)
    }

    @Test
    func outputWithoutItsOwnGrantCannotBeProjectedThroughLineage() throws {
        let projection = try Self.projection(grantRecording: false)
        #expect(throws: (any Error).self) { try projection.resource(at: Self.recording) }
    }
}
