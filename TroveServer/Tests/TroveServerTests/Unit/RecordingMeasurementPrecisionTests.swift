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


struct RecordingMeasurementPrecisionTests {
    @Test("Attachment authority compares exact microseconds without a floating-point display roundtrip", arguments: ["000516", "000619", "999999"])
    func sameWireInstantIsAdmitted(_ fraction: String) throws {
        let instant = "2026-11-14T12:06:40.\(fraction)Z"
        let bounds = try ClinicalMeasurementBounds(sourceStart: instant, sourceEnd: instant)
        let date = try TroveDateTranscoder().decode(instant)
        let bytes = Data("timestamp,precededByGap\n1794658000.\(fraction),0\n".utf8)
        let document = try Self.document(instant: instant, bytes: bytes)
        let attachment = try Self.attachment(date: date, bytes: bytes)
        try attachment.validate(document: document, bounds: bounds)
        let projected = try FHIRRecordingProjection.project(document, external: attachment)
        #expect(projected.bounds == bounds)
        // One nanosecond is a real mismatch even when a Date projection could hide it.
        let shifted = "2026-11-14T12:06:40.\(fraction)001Z"
        let different = try ClinicalMeasurementBounds(sourceStart: shifted, sourceEnd: shifted)
        #expect(throws: (any Error).self) { try attachment.validate(document: document, bounds: different) }
    }
}


extension RecordingMeasurementPrecisionTests {
    private static func document(instant: String, bytes: Data) throws -> DocumentReference {
        let object: [String: Any] = [
            "resourceType": "DocumentReference", "status": "current",
            "meta": ["profile": [FHIRRecordingProjection.profile]],
            "extension": [
                [
                    "url": try #require(Canonicals.healthKitSourceTypeExtension.value?.url.absoluteString),
                    "valueCode": SampleType.heartbeatSeries.hkSampleType.identifier
                ]
            ],
            "context": ["period": ["start": instant, "end": instant]],
            "content": [
                [
                    "format": ["system": FHIRRecordingProjection.formatSystem, "code": RegisteredRecordingFormat.beatIntervalSeries.rawValue],
                    "attachment": [
                        "contentType": "text/csv", "url": "recordings/heartbeat.csv", "size": bytes.count,
                        "hash": Data(Insecure.SHA1.hash(data: bytes)).base64EncodedString()
                    ]
                ]
            ]
        ]
        return try JSONDecoder().decode(DocumentReference.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private static func attachment(date: Date, bytes: Data) throws -> ClinicalRecordingAttachment {
        let participantID = UUID(), sourceID = UUID(), fullURL = "urn:uuid:73f859eb-b777-4ff7-9dc4-8ef872a5f354"
        let digest = ArtifactStore.digest(bytes)
        let declaration = try RecordingTransferDeclaration(
            attachmentPath: "recordings/heartbeat.csv",
            outputFullURL: fullURL,
            profile: FHIRRecordingProjection.profile,
            format: .beatIntervalSeries,
            effectiveAt: date,
            effectiveEnd: date,
            content: .init(
                storedByteCount: bytes.count,
                storedSHA256: digest,
                sourceByteCount: bytes.count,
                sourceSHA256: digest,
                encoding: .identity
            ),
            targets: [.init(consentID: UUID(), outputFullURLs: [fullURL])],
            sourceTypeIdentifier: SampleType.heartbeatSeries.hkSampleType.identifier
        )
        return try .init(
            reference: .init(
                id: UUID(),
                ownerID: participantID,
                purpose: .recording,
                digest: digest,
                byteCount: bytes.count,
                scope: .participantSource(.init(participantID: participantID, sourceBindingID: sourceID))
            ),
            declaration: declaration,
            content: .init(bounds: RecordingRouteBounds(first: date, last: date), attachmentSHA1: Data(Insecure.SHA1.hash(data: bytes)))
        )
    }
}
