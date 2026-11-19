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


/// The disclosure rule on single derived resources; the study data and recording routes are covered separately.
struct StudyDeviceUnitDisclosureTests {
    private static let role = "https://grovealliance.org/fhir/mobile/CodeSystem/grove-identifier-role"
    private static let deviceBundle = "com.apple.health.94C8E349-0D09-4184-BF6C-AF11692FA465"
    private static let v20203 = "http://terminology.hl7.org/CodeSystem/v2-0203"
    private static let deviceIdentifierType = Canonicals.root + "/mobile/CodeSystem/grove-device-identifier-type"

    @Test
    func recordingDeviceKeepsOnlyFactsAboutItsKind() throws {
        let device: [String: Any] = [
            "resourceType": "Device",
            "meta": ["profile": [Canonicals.root + "/mobile/StructureDefinition/grove-recording-device"]],
            "serialNumber": "SERIAL-1", "_serialNumber": ["extension": [["url": "https://example.test/note", "valueString": "SERIAL-NOTE"]]],
            "manufacturer": "Apple Inc.", "modelNumber": "Watch7,12",
            "lotNumber": "LOT-NUMBER", "manufactureDate": "2026-01-01", "distinctIdentifier": "DISTINCT-ID",
            "deviceName": [
                ["name": "Alex's Watch", "type": "user-friendly-name"], ["name": "Alex", "type": "patient-reported-name"],
                ["name": "Apple Watch", "type": "model-name"]
            ],
            "identifier": [
                Self.identifier("device-snapshot", value: "SNAPSHOT"),
                Self.identifier("recording-device", value: "UNIT-TOKEN"),
                [
                    "system": "https://example.test/local", "value": "LOCAL-ID",
                    "type": ["coding": [["system": Self.deviceIdentifierType, "code": "device-local-identifier"]]]
                ],
                ["system": "https://example.test/open-slice", "value": "OPEN-SLICE"]
            ],
            "udiCarrier": [
                [
                    "deviceIdentifier": "(01)00844588003288", "carrierHRF": "(01)00844588003288(21)LOT-HRF",
                    "extension": [["url": Canonicals.root + "/mobile/StructureDefinition/grove-udi-production-identifier", "valueString": "LOT-7"]]
                ],
                ["carrierAIDC": "QUlEQw=="]
            ]
        ]
        let result = try Self.withheld(device)
        let text = try Self.text(result)
        let unit = [
            "SERIAL", "UNIT-TOKEN", "LOCAL-ID", "OPEN-SLICE", "Alex", "LOT-", "QUlEQw==", "carrierHRF", "2026-01-01", "DISTINCT-ID"
        ]
        for value in unit {
            #expect(!text.contains(value), "\(value) identifies the unit")
        }
        #expect(result["manufacturer"] as? String == "Apple Inc." && result["modelNumber"] as? String == "Watch7,12")
        #expect(result["deviceName"] as? [[String: String]] == [["name": "Apple Watch", "type": "model-name"]])
        #expect(result["identifier"] == nil, "A recording or host Device keeps no identifier")
        #expect(result["udiCarrier"] as? [[String: String]] == [["deviceIdentifier": "(01)00844588003288"]])
    }

    @Test
    func applicationNamesTravelUnlessHealthKitAssignedThemToOneDevice() throws {
        let profile = Canonicals.root + "/healthkit/StructureDefinition/healthkit-application-device"
        func application(_ bundle: String) -> [String: Any] {
            [
                "resourceType": "Device", "meta": ["profile": [profile]],
                "deviceName": [["name": "Writer", "type": "user-friendly-name"]],
                "identifier": [Self.bundleIdentifier(bundle)]
            ]
        }
        let ordinary = try Self.withheld(application("org.example.writer"))
        #expect((ordinary["deviceName"] as? [Any])?.count == 1 && (ordinary["identifier"] as? [Any])?.count == 1)
        let device = try Self.withheld(application(Self.deviceBundle))
        #expect(device["deviceName"] == nil && device["identifier"] == nil)
    }

    @Test
    func applicationDevicesFollowTheAllowlistBesideTheirNameAndBundleIdentifier() throws {
        let device: [String: Any] = [
            "resourceType": "Device",
            "meta": ["profile": [Canonicals.root + "/mobile/StructureDefinition/grove-application-device"]],
            "serialNumber": "APP-SERIAL", "lotNumber": "APP-LOT",
            "udiCarrier": [["deviceIdentifier": "(01)00844588003288", "carrierHRF": "APP-HRF"]],
            "deviceName": [["name": "Writer", "type": "user-friendly-name"], ["name": "Alex", "type": "patient-reported-name"]],
            "identifier": [
                Self.bundleIdentifier("org.example.writer"), ["system": "https://example.test/open-slice", "value": "APP-SLICE"],
                ["system": "https://example.test/serials", "value": "APP-SNO", "type": ["coding": [["system": Self.v20203, "code": "SNO"]]]]
            ]
        ]
        let result = try Self.withheld(device)
        let text = try Self.text(result)
        for value in ["APP-SERIAL", "APP-LOT", "APP-HRF", "Alex", "APP-SLICE", "APP-SNO"] {
            #expect(!text.contains(value), "\(value) is not a fact about the application")
        }
        #expect(result["deviceName"] as? [[String: String]] == [["name": "Writer", "type": "user-friendly-name"]])
        #expect((result["identifier"] as? [[String: Any]])?.compactMap { $0["value"] as? String } == ["org.example.writer"])
        #expect(result["udiCarrier"] as? [[String: String]] == [["deviceIdentifier": "(01)00844588003288"]])
    }

    @Test
    func referencesToDevicesKeepOnlyTheirAddressAndType() throws {
        let observation: [String: Any] = [
            "resourceType": "Observation",
            "device": ["reference": "urn:uuid:device", "type": "Device", "display": "Alex's Apple Watch"],
            "performer": [["reference": "urn:uuid:patient", "display": "Participant"]],
            "extension": [
                [
                    "url": "http://hl7.org/fhir/StructureDefinition/observation-gatewayDevice",
                    "valueReference": ["reference": "urn:uuid:device", "display": "Alex's iPhone"]
                ]
            ]
        ]
        let result = try Self.withheld(observation, devices: ["urn:uuid:device"])
        let text = try Self.text(result)
        #expect(!text.contains("Alex") && text.contains("Participant"))
        #expect(result["device"] as? [String: String] == ["reference": "urn:uuid:device", "type": "Device"])
    }

    @Test
    func deviceAssignedPrefixesMatchInAnyCaseAndRecordingFormatsNeedTheirSystem() throws {
        let segment = "https://example.test/native/" + FHIRSyncRecordIdentifier.systemPathSegment + "/"
        let observation: [String: Any] = [
            "resourceType": "Observation",
            "identifier": [["system": segment + Self.deviceBundle.uppercased(), "value": "DEVICE-SYNC"]]
        ]
        #expect(try !Self.text(Self.withheld(observation)).contains("DEVICE-SYNC"))
        let document: [String: Any] = [
            "resourceType": "DocumentReference",
            "content": [
                [
                    "format": ["system": "https://example.test/other-formats", "code": RegisteredRecordingFormat.heartRateSamples.rawValue],
                    "attachment": ["contentType": "text/csv", "url": "/studies/a/recording", "size": 2]
                ]
            ]
        ]
        #expect(try !Self.text(Self.withheld(document)).contains("/studies/a/recording"), "An unknown format system is opaque")
    }

    @Test
    func sourceRevisionAndMetadataLoseOnlyUnitFacts() throws {
        let provenance: [String: Any] = [
            "resourceType": "Provenance",
            "entity": [
                ["role": "source", "extension": [Self.revision(["sourceName": "Alex's Watch", "sourceBundleIdentifier": Self.deviceBundle])]],
                ["role": "source", "extension": [Self.revision(["sourceName": "Writer", "sourceBundleIdentifier": "org.example.writer"])]]
            ]
        ]
        let entities = try #require(try Self.withheld(provenance)["entity"] as? [[String: Any]])
        #expect(entities[0]["extension"] == nil, "A revision with no fact left is not stated")
        let application = try Self.text(entities[1])
        #expect(application.contains("org.example.writer") && application.contains("Writer"), "An application keeps its name")

        let entries = ["HKDeviceSerialNumber", "HKDeviceName", "HKUDIProductionIdentifier", "HKUDIDeviceIdentifier", "com.example.note"]
        let observation: [String: Any] = [
            "resourceType": "Observation",
            "extension": [
                [
                    "url": FHIRHealthKitMetadataBoundary.url,
                    "extension": entries.map { key in
                        ["url": "entry", "extension": [["url": "key", "valueString": key], ["url": "value", "valueString": "value-of-\(key)"]]]
                    }
                ]
            ]
        ]
        let text = try Self.text(Self.withheld(observation))
        #expect(text.contains("HKUDIDeviceIdentifier") && text.contains("com.example.note"))
        for key in entries.prefix(3) { #expect(!text.contains(key)) }
    }

    @Test
    func readableSyncIdentifiersScopedToADeviceAreWithheld() throws {
        let segment = "https://example.test/native/" + FHIRSyncRecordIdentifier.systemPathSegment + "/"
        let observation: [String: Any] = [
            "resourceType": "Observation",
            "identifier": [
                ["system": segment + Self.deviceBundle, "value": "DEVICE-SYNC"],
                ["system": segment + "org.example.writer", "value": "APP-SYNC"]
            ]
        ]
        let text = try Self.text(Self.withheld(observation))
        #expect(!text.contains("DEVICE-SYNC") && text.contains("APP-SYNC"))
    }

    @Test
    func eventsReceiveUnitFactsOnlyWhenEveryGrantsRevisionDoes() throws {
        let study = UUID(), event = UUID(), first = UUID(), second = UUID()
        let policies = try [
            first: PublishedCollectionPolicy.compile(studyID: study, revision: 1, requirements: [], receivesDeviceUnitIdentifiers: true),
            second: PublishedCollectionPolicy.compile(studyID: study, revision: 2, requirements: [], receivesDeviceUnitIdentifiers: false)
        ]
        let entitled = StudyDeviceUnitDisclosure.Grant(eventID: event, publicationID: first, revision: 1)
        let withheld = StudyDeviceUnitDisclosure.Grant(eventID: event, publicationID: second, revision: 2)
        #expect(try StudyDeviceUnitDisclosure.receivingEvents([entitled], policies: policies, studyID: study) == [event])
        #expect(try StudyDeviceUnitDisclosure.receivingEvents([entitled, withheld], policies: policies, studyID: study).isEmpty)
        #expect(try StudyDeviceUnitDisclosure.receivingEvents([], policies: policies, studyID: study).isEmpty)
    }

    @Test(arguments: ["missing", "other-study", "revision", "old-schema"])
    func corruptOrUnknownPublicationEvidenceFails(failure: String) throws {
        let study = UUID(), publication = UUID()
        var policy = try PublishedCollectionPolicy.compile(
            studyID: failure == "other-study" ? UUID() : study, revision: 1, requirements: [], receivesDeviceUnitIdentifiers: true
        )
        if failure == "old-schema" {
            var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)) as? [String: Any])
            json["schemaVersion"] = 5
            policy = try JSONDecoder().decode(PublishedCollectionPolicy.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let grant = StudyDeviceUnitDisclosure.Grant(eventID: UUID(), publicationID: publication, revision: failure == "revision" ? 2 : 1)
        #expect(throws: ServerError.self) {
            try StudyDeviceUnitDisclosure.receivingEvents([grant], policies: failure == "missing" ? [:] : [publication: policy], studyID: study)
        }
    }

    @Test
    func opaqueRecordingsLoseTheirContentAndLocation() throws {
        func document(_ format: RegisteredRecordingFormat) -> [String: Any] {
            [
                "resourceType": "DocumentReference",
                "content": [
                    [
                        "format": ["system": FHIRRecordingProjection.formatSystem, "code": format.rawValue],
                        "attachment": ["contentType": "application/json", "url": "/studies/a/recording", "data": "e30=", "size": 2, "hash": "AAAA"]
                    ]
                ]
            ]
        }
        let opaque = try Self.withheld(document(.providerRecording))
        let attachment = try #require(((opaque["content"] as? [[String: Any]])?.first)?["attachment"] as? [String: Any])
        #expect(attachment["url"] == nil && attachment["data"] == nil)
        #expect(attachment["size"] as? Int == 2 && attachment["hash"] as? String == "AAAA")
        let tabular = try Self.withheld(document(.heartRateSamples))
        #expect(try Self.text(tabular).contains("/studies/a/recording"))
    }

    @Test(arguments: RegisteredRecordingFormat.allCases)
    func onlyClosedSampleGrammarsAndClinicalDocumentsAreReleasedUnchanged(format: RegisteredRecordingFormat) {
        let opaque: Set<RegisteredRecordingFormat> = [.nativeRecording, .providerRecording, .fhirCollectionBundle]
        #expect(StudyDeviceUnitDisclosure.releasesUnchanged(format) == !opaque.contains(format))
    }
}


extension StudyDeviceUnitDisclosureTests {
    private static func identifier(_ code: String, value: String) -> [String: Any] {
        ["system": "https://example.test/\(code)", "value": value, "type": ["coding": [["system": role, "code": code]]]]
    }

    private static func revision(_ facts: [String: String]) -> [String: Any] {
        [
            "url": Canonicals.root + "/healthkit/StructureDefinition/healthkit-source-revision",
            "extension": facts.sorted { $0.key < $1.key }.map { ["url": $0.key, "valueString": $0.value] }
        ]
    }

    private static func bundleIdentifier(_ value: String) -> [String: Any] {
        [
            "system": Canonicals.appleBundleIdentifierSystem, "value": value,
            "type": ["coding": [["system": Canonicals.root + "/healthkit/CodeSystem/healthkit-identifier-type", "code": "apple-bundle-id"]]]
        ]
    }

    private static func withheld(_ resource: [String: Any], devices: Set<String> = []) throws -> [String: Any] {
        guard case .object(var members) = try json(resource) else { throw FHIRValidationClient.invalid }
        try StudyDeviceUnitDisclosure.withhold(from: &members) { devices.contains($0) }
        return try #require(JSONSerialization.jsonObject(with: StudyProjectionJSON.object(members).encoded()) as? [String: Any])
    }

    private static func text(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    /// Mirrors the projection reader: scalars keep their exact JSON tokens.
    private static func json(_ value: Any) throws -> StudyProjectionJSON {
        switch value {
        case let object as [String: Any]: .object(try object.mapValues(json))
        case let array as [Any]: .array(try array.map(json))
        case let string as String: try .string(string)
        default: .scalar(try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
        }
    }
}
