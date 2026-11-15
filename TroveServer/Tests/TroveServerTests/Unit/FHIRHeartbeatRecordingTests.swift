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
import GroveHealthKit
import ModelsR4
import Testing
import TroveAPITypes
@testable import TroveServer


struct FHIRHeartbeatRecordingTests {
    @Test("Heartbeat selection preserves the complete source interval, including time before the first beat")
    func retainsSessionBoundsAndExactSource() throws {
        let document = try Self.document()
        let facts = try FHIRRecordingProjection.project(document)
        #expect(facts.format == .beatIntervalSeries)
        #expect(facts.source.repository == .healthKit)
        #expect(facts.source.identifier == SampleType.heartbeatSeries.hkSampleType.identifier)
        #expect(facts.bounds == (try ClinicalMeasurementBounds(
            sourceStart: "2026-08-17T22:30:00Z", sourceEnd: "2026-08-17T22:31:00Z"
        )))
        let output = ClinicalGrantStore.Output(
            fullURL: "urn:uuid:73f859eb-b777-4ff7-9dc4-8ef872a5f354",
            profile: facts.profile,
            measurementBounds: facts.bounds,
            codeSystem: FHIRRecordingProjection.formatSystem,
            code: facts.format.rawValue,
            sourceTypeIdentifier: facts.source.identifier
        )
        #expect(!output.isWorkoutRoute)
        #expect(output.collectionProfile == facts.profile)
        #expect(output.collectionProfile != CollectionObservationProfile.workout.rawValue)
    }

    @Test("An empty completed series still carries its source interval")
    func emptySeriesRequiresExplicitPeriod() throws {
        let document = try Self.document(payload: "timestamp,precededByGap\n")
        let facts = try FHIRRecordingProjection.project(document)
        #expect(facts.bounds.end != nil)
        var missing = document
        missing.context = nil
        #expect(throws: (any Error).self) { try FHIRRecordingProjection.project(missing) }
    }

    @Test("A transfer declaration must name the source carried by its final document")
    func requiresMatchingTransferSource() throws {
        let bytes = Data("timestamp,precededByGap\n1787005801,0\n1787005802,1\n".utf8)
        var document = try Self.document()
        let attachment: [String: Any] = [
            "contentType": "text/csv", "url": "recordings/heartbeat.csv", "size": bytes.count,
            "hash": Data(Insecure.SHA1.hash(data: bytes)).base64EncodedString()
        ]
        document.content[0].attachment = try JSONDecoder().decode(Attachment.self, from: JSONSerialization.data(withJSONObject: attachment))
        let fullURL = "urn:uuid:73f859eb-b777-4ff7-9dc4-8ef872a5f354"
        let source = SampleType.heartbeatSeries.hkSampleType.identifier
        let declaration = try RecordingTransferDeclaration(
            attachmentPath: "recordings/heartbeat.csv",
            outputFullURL: fullURL,
            profile: FHIRRecordingProjection.profile,
            format: .beatIntervalSeries,
            effectiveAt: Date(timeIntervalSince1970: 1_787_005_800),
            effectiveEnd: Date(timeIntervalSince1970: 1_787_005_860),
            content: .init(
                storedByteCount: bytes.count,
                storedSHA256: ArtifactStore.digest(bytes),
                sourceByteCount: bytes.count,
                sourceSHA256: ArtifactStore.digest(bytes),
                encoding: .identity
            ),
            targets: [.init(consentID: UUID(), outputFullURLs: [fullURL])],
            sourceTypeIdentifier: source
        )
        try ClinicalRecordingAttachment.validate(document: document, declaration: declaration)
        document.extension = [
            Extension(url: Canonicals.healthKitSourceTypeExtension, value: .code(FHIRPrimitive(
                FHIRString(SampleType.workoutRoute.hkSampleType.identifier)
            )))
        ]
        #expect(throws: (any Error).self) { try ClinicalRecordingAttachment.validate(document: document, declaration: declaration) }
    }

    @Test(arguments: ["source", "format", "period", "gap", "reverse", "outside"])
    func refusesMismatchedOrInvalidSeries(_ corruption: String) throws {
        var payload = "timestamp,precededByGap\n1787005801,0\n1787005802,1\n"
        switch corruption {
        case "gap": payload = "timestamp,precededByGap\n1787005801,2\n"
        case "reverse": payload = "timestamp,precededByGap\n1787005802,0\n1787005801,1\n"
        case "outside": payload = "timestamp,precededByGap\n1787005861,0\n"
        default: break
        }
        var document = try Self.document(payload: payload)
        switch corruption {
        case "source":
            document.extension = [
                Extension(url: Canonicals.healthKitSourceTypeExtension, value: .code(FHIRPrimitive(
                    FHIRString(SampleType.workoutRoute.hkSampleType.identifier)
                )))
            ]
        case "format": document.content[0].format?.code = FHIRPrimitive(FHIRString(RegisteredRecordingFormat.locationTrackSamples.rawValue))
        case "period": document.context = nil
        default: break
        }
        #expect(throws: (any Error).self) { try FHIRRecordingProjection.project(document) }
    }
}


extension FHIRHeartbeatRecordingTests {
    private static func document(payload: String = "timestamp,precededByGap\n1787005801,0\n1787005802,1\n") throws -> DocumentReference {
        let json: [String: Any] = [
            "resourceType": "DocumentReference",
            "status": "current",
            "meta": ["profile": [FHIRRecordingProjection.profile]],
            "extension": [
                [
                    "url": try #require(Canonicals.healthKitSourceTypeExtension.value?.url.absoluteString),
                    "valueCode": SampleType.heartbeatSeries.hkSampleType.identifier
                ]
            ],
            "context": ["period": ["start": "2026-08-17T22:30:00Z", "end": "2026-08-17T22:31:00Z"]],
            "content": [
                [
                    "format": ["system": FHIRRecordingProjection.formatSystem, "code": RegisteredRecordingFormat.beatIntervalSeries.rawValue],
                    "attachment": ["contentType": "text/csv", "data": Data(payload.utf8).base64EncodedString()]
                ]
            ]
        ]
        return try JSONDecoder().decode(DocumentReference.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
