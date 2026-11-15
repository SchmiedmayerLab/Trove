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
import TroveAPITypes


struct RecordingTransferCommitmentTests {
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
