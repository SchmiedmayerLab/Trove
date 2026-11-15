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


/// Exact declaration evidence shared by the sender and receiver. This is not clinical validation or collection authority.
public struct RecordingTransferCommitment: Sendable {
    public enum Failure: Error, Equatable {
        case invalidDeclaration
        case invalidEvidence
        case receiptMismatch
    }

    private struct Evidence: Codable {
        let version: Int
        let attachmentPath: String
        let outputFullURL: String
        let profile: String
        let format: String
        let effectiveAt: Date
        let effectiveEnd: Date
        let content: Components.Schemas.RecordingTransferContent
        let targetIntent: String
    }

    public static let maximumBytes = 65_536
    public let declaration: Components.Schemas.RecordingTransferDeclaration
    public let intent: EventTargetIntent
    public let serialized: Data
    public let sha256: String

    public init(_ declaration: Components.Schemas.RecordingTransferDeclaration) throws {
        let path = declaration.attachmentPath
        let content = declaration.content
        guard (1...512).contains(path.utf8.count),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              path.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 47, 95].contains($0) }),
              declaration.profile == Profile.healthkitRecordingDocument.value?.url.absoluteString,
              RegisteredRecordingFormat(rawValue: declaration.format) != nil,
              Self.validDate(declaration.effectiveAt), Self.validDate(declaration.effectiveEnd),
              declaration.effectiveAt <= declaration.effectiveEnd,
              (1...Int64(Int32.max)).contains(content.storedByteCount), (1...Int64(Int32.max)).contains(content.sourceByteCount),
              Self.isDigest(content.storedSHA256), Self.isDigest(content.sourceSHA256),
              content.encoding != .identity || (content.storedByteCount == content.sourceByteCount && content.storedSHA256 == content.sourceSHA256),
              !declaration.targets.isEmpty else { throw Failure.invalidDeclaration }
        let intent = try EventTargetIntent(targets: declaration.targets.map { target in
            guard let consentID = UUID(uuidString: target.consentId), target.outputFullUrls == [declaration.outputFullUrl] else {
                throw Failure.invalidDeclaration
            }
            return .init(consentID: consentID, outputFullURLs: target.outputFullUrls)
        })
        var declaration = declaration
        let dates = TroveDateTranscoder()
        declaration.effectiveAt = try dates.decode(dates.encode(declaration.effectiveAt))
        declaration.effectiveEnd = try dates.decode(dates.encode(declaration.effectiveEnd))
        declaration.targets = intent.targets.map { .init(consentId: $0.consentID.uuidString.lowercased(), outputFullUrls: $0.outputFullURLs) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(Evidence(
            version: 1,
            attachmentPath: path,
            outputFullURL: declaration.outputFullUrl,
            profile: declaration.profile,
            format: declaration.format,
            effectiveAt: declaration.effectiveAt,
            effectiveEnd: declaration.effectiveEnd,
            content: content,
            targetIntent: intent.serialized
        ))
        guard bytes.count <= Self.maximumBytes else { throw Failure.invalidDeclaration }
        self.declaration = declaration
        self.intent = intent
        serialized = bytes
        sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    public init(restoring bytes: Data, sha256: String) throws {
        guard bytes.count <= Self.maximumBytes else { throw Failure.invalidEvidence }
        do {
            let evidence = try JSONDecoder().decode(Evidence.self, from: bytes)
            guard evidence.version == 1 else { throw Failure.invalidEvidence }
            let targets = try JSONDecoder().decode([EventTargetIntent.Target].self, from: Data(evidence.targetIntent.utf8))
            try self.init(.init(
                attachmentPath: evidence.attachmentPath,
                outputFullUrl: evidence.outputFullURL,
                profile: evidence.profile,
                format: evidence.format,
                effectiveAt: evidence.effectiveAt,
                effectiveEnd: evidence.effectiveEnd,
                content: evidence.content,
                targets: targets.map { .init(consentId: $0.consentID.uuidString.lowercased(), outputFullUrls: $0.outputFullURLs) }
            ))
            guard serialized == bytes, self.sha256 == sha256 else { throw Failure.invalidEvidence }
        } catch {
            throw Failure.invalidEvidence
        }
    }

    public func verify(_ registration: Components.Schemas.RecordingTransferRegistration, sourceID: UUID, transferID: UUID) throws {
        guard UUID(uuidString: registration.sourceId) == sourceID, UUID(uuidString: registration.transferId) == transferID,
              registration.declarationSHA256 == sha256, registration.storedByteCount == declaration.content.storedByteCount,
              registration.storedSHA256 == declaration.content.storedSHA256 else { throw Failure.receiptMismatch }
    }

    /// Expired evidence may be recovered, but is not usable for a new clinical attachment admission.
    public func verify(_ receipt: Components.Schemas.RecordingTransferReceipt, sourceID: UUID, transferID: UUID) throws {
        guard UUID(uuidString: receipt.sourceId) == sourceID, UUID(uuidString: receipt.transferId) == transferID,
              UUID(uuidString: receipt.artifactId) != nil, receipt.declarationSHA256 == sha256,
              receipt.storedByteCount == declaration.content.storedByteCount, receipt.storedSHA256 == declaration.content.storedSHA256,
              Self.validDate(receipt.verifiedAt), Self.validDate(receipt.expiresAt), receipt.verifiedAt < receipt.expiresAt else {
            throw Failure.receiptMismatch
        }
    }
}


extension RecordingTransferCommitment {
    private static func validDate(_ date: Date) -> Bool { (0...253_402_300_799).contains(date.timeIntervalSince1970) }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
