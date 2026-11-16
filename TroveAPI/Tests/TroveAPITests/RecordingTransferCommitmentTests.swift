//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveHealthKit
import GroveSensorKitFHIR
import Testing
import TroveAPITypes


struct RecordingTransferCommitmentTests {
    private static let retainedRouteEvidence = Data([
        "{\"attachmentPath\":\"recordings/route.csv\",\"content\":{\"encoding\":\"identity\",\"sourceByteCount\":3,\"sourc",
        "eSHA256\":\"1111111111111111111111111111111111111111111111111111111111111111\",\"storedByteCount\":3,\"sto",
        "redSHA256\":\"1111111111111111111111111111111111111111111111111111111111111111\"},\"effectiveAt\":8216928",
        "00,\"effectiveEnd\":821692860,\"format\":\"location-track-samples\",\"outputFullURL\":\"urn:uuid:00000000-000",
        "0-4000-8000-000000000001\",\"profile\":\"https://grovealliance.org/fhir/healthkit/StructureDefinition/he",
        "althkit-recording-document\",\"targetIntent\":\"[{\\\"consentId\\\":\\\"00000000-0000-4000-8000-000000000002\\\"",
        ",\\\"outputFullUrls\\\":[\\\"urn:uuid:00000000-0000-4000-8000-000000000001\\\"]}]\",\"version\":1}"
    ].joined().utf8)

    @Test
    func retainedRouteEvidenceRestoresByteForByteWithoutInventingASourceToken() throws {
        let bytes = Self.retainedRouteEvidence
        let restored = try RecordingTransferCommitment(
            restoring: bytes, sha256: "0d02fcb1a02c6d357177c538d73dbc7161b8b50d192a9b20e3b29282235b9744"
        )
        #expect(restored.serialized == bytes && restored.declaration.sourceTypeIdentifier == nil)
        var explicit = restored.declaration
        explicit.sourceTypeIdentifier = SampleType.workoutRoute.hkSampleType.identifier
        let changed = try RecordingTransferCommitment(explicit)
        #expect(changed.sha256 != restored.sha256)
        #expect(try RecordingTransferCommitment(restoring: changed.serialized, sha256: changed.sha256).declaration == explicit)
    }

    @Test
    func heartbeatRecordingRequiresItsExactSourceRatherThanRouteAuthority() throws {
        var declaration = try Self.declaration()
        declaration.format = RegisteredRecordingFormat.beatIntervalSeries.rawValue
        #expect(throws: (any Error).self) { try RecordingTransferCommitment(declaration) }
        declaration.sourceTypeIdentifier = SampleType.workoutRoute.hkSampleType.identifier
        #expect(throws: (any Error).self) { try RecordingTransferCommitment(declaration) }
        declaration.sourceTypeIdentifier = SampleType.heartbeatSeries.hkSampleType.identifier
        let commitment = try RecordingTransferCommitment(declaration)
        #expect(commitment.declaration.sourceTypeIdentifier == declaration.sourceTypeIdentifier)
        declaration.format = RegisteredRecordingFormat.locationTrackSamples.rawValue
        #expect(throws: (any Error).self) { try RecordingTransferCommitment(declaration) }
    }

    @Test
    func sensorRecordingDeclarationUsesItsExactCatalogSourceProfileAndFormat() throws {
        let entry = try #require(SensorKitCatalog.current.entries.first {
            $0.implementedOutput != nil && $0.rawFormats.contains(.triaxialAccelerationSamples)
        })
        var declaration = try Self.declaration()
        declaration.profile = SensorKitContract.recordingDocumentProfile
        declaration.format = RegisteredRecordingFormat.triaxialAccelerationSamples.rawValue
        declaration.sourceTypeIdentifier = entry.sourceToken
        let commitment = try RecordingTransferCommitment(declaration)
        #expect(commitment.declaration.sourceTypeIdentifier == entry.sourceToken)
        #expect(commitment.declaration.format == declaration.format)
        #expect(try RecordingTransferCommitment(restoring: commitment.serialized, sha256: commitment.sha256).declaration == commitment.declaration)
        declaration.sourceTypeIdentifier = nil
        #expect(throws: (any Error).self) { try RecordingTransferCommitment(declaration) }
        declaration.sourceTypeIdentifier = "unknown-sensor"
        #expect(throws: (any Error).self) { try RecordingTransferCommitment(declaration) }
        declaration.sourceTypeIdentifier = entry.sourceToken
        declaration.format = RegisteredRecordingFormat.clinicalDocument.rawValue
        #expect(throws: (any Error).self) { try RecordingTransferCommitment(declaration) }
    }

    @Test
    func canonicalEvidenceSurvivesWireDatePrecisionAndTargetOrdering() throws {
        var declaration = try Self.declaration()
        declaration.effectiveAt = Date(timeIntervalSince1970: 1_800_000_000.1234567)
        declaration.targets.append(.init(consentId: UUID().uuidString, outputFullUrls: [declaration.outputFullUrl]))
        let first = try RecordingTransferCommitment(declaration)
        let codec = TroveDateTranscoder()
        declaration.effectiveAt = try codec.decode(codec.encode(declaration.effectiveAt))
        declaration.targets.reverse()
        let second = try RecordingTransferCommitment(declaration)
        #expect(first.serialized == second.serialized)
        #expect(first.sha256 == second.sha256)
        let restored = try RecordingTransferCommitment(restoring: first.serialized, sha256: first.sha256)
        #expect(restored.declaration == first.declaration)
        #expect(throws: RecordingTransferCommitment.Failure.invalidEvidence) {
            try RecordingTransferCommitment(restoring: first.serialized + Data([32]), sha256: first.sha256)
        }
    }

    @Test(arguments: ["path", "digest", "size", "encoding", "profile", "format", "date", "target"])
    func invalidDeclarationsCannotBeCommitted(field: String) throws {
        var declaration = try Self.declaration()
        switch field {
        case "path": declaration.attachmentPath = "../route.csv"
        case "digest": declaration.content.sourceSHA256 = String(repeating: "Z", count: 64)
        case "size": declaration.content.storedByteCount = 0
        case "encoding": declaration.content.sourceByteCount += 1
        case "profile": declaration.profile = "https://example.test/unknown"
        case "format": declaration.format = "unknown"
        case "date": declaration.effectiveEnd = declaration.effectiveAt.addingTimeInterval(-1)
        default: declaration.targets[0].outputFullUrls = ["urn:uuid:other"]
        }
        #expect(throws: (any Error).self) { try RecordingTransferCommitment(declaration) }
    }

    @Test(arguments: ["source", "transfer", "declaration", "size", "digest", "artifact", "dates"])
    func receiptMustCommitTheEntireDeclaredTransfer(field: String) throws {
        let commitment = try RecordingTransferCommitment(Self.declaration())
        let sourceID = UUID(), transferID = UUID()
        var receipt = Components.Schemas.RecordingTransferReceipt(
            sourceId: sourceID.uuidString,
            transferId: transferID.uuidString,
            artifactId: UUID().uuidString,
            declarationSHA256: commitment.sha256,
            storedByteCount: commitment.declaration.content.storedByteCount,
            storedSHA256: commitment.declaration.content.storedSHA256,
            verifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_800_003_600)
        )
        try commitment.verify(receipt, sourceID: sourceID, transferID: transferID)
        switch field {
        case "source": receipt.sourceId = UUID().uuidString
        case "transfer": receipt.transferId = UUID().uuidString
        case "declaration": receipt.declarationSHA256 = String(repeating: "0", count: 64)
        case "size": receipt.storedByteCount += 1
        case "digest": receipt.storedSHA256 = String(repeating: "0", count: 64)
        case "artifact": receipt.artifactId = "invalid"
        default: receipt.expiresAt = receipt.verifiedAt
        }
        #expect(throws: RecordingTransferCommitment.Failure.receiptMismatch) {
            try commitment.verify(receipt, sourceID: sourceID, transferID: transferID)
        }
    }
}


extension RecordingTransferCommitmentTests {
    static func declaration() throws -> Components.Schemas.RecordingTransferDeclaration {
        .init(
            attachmentPath: "recordings/route.csv",
            outputFullUrl: "urn:uuid:00000000-0000-4000-8000-000000000001",
            profile: try #require(Profile.healthkitRecordingDocument.value?.url.absoluteString),
            format: RegisteredRecordingFormat.locationTrackSamples.rawValue,
            effectiveAt: Date(timeIntervalSince1970: 1_800_000_000),
            effectiveEnd: Date(timeIntervalSince1970: 1_800_000_060),
            content: .init(
                encoding: .identity,
                storedByteCount: 3,
                storedSHA256: String(repeating: "1", count: 64),
                sourceByteCount: 3,
                sourceSHA256: String(repeating: "1", count: 64)
            ),
            targets: [.init(consentId: UUID().uuidString, outputFullUrls: ["urn:uuid:00000000-0000-4000-8000-000000000001"])]
        )
    }
}
