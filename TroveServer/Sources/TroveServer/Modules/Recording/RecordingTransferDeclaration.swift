//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import TroveAPITypes


/// Immutable transport facts. Clinical admission must independently validate source facts against decoded bytes.
struct RecordingTransferDeclaration: Sendable {
    enum Encoding: String, Codable, Sendable { case identity, zstd }

    struct Content: Codable, Sendable {
        let storedByteCount: Int
        let storedSHA256: String
        let sourceByteCount: Int
        let sourceSHA256: String
        let encoding: Encoding
    }

    static let maximumBytes = RecordingTransferCommitment.maximumBytes

    let content: Content
    let attachmentPath: String
    let output: ClinicalGrantStore.Output
    let intent: ClinicalEventIntent
    let serialized: String
    let sha256: String

    init(
        attachmentPath: String,
        outputFullURL: String,
        profile: String,
        format: RegisteredRecordingFormat,
        effectiveAt: Date,
        effectiveEnd: Date,
        content: Content,
        targets: [ClinicalEventTarget],
        sourceTypeIdentifier: String? = nil
    ) throws {
        let commitment: RecordingTransferCommitment
        do {
            commitment = try .init(.init(
                attachmentPath: attachmentPath,
                outputFullUrl: outputFullURL,
                profile: profile,
                sourceTypeIdentifier: sourceTypeIdentifier,
                format: format.rawValue,
                effectiveAt: effectiveAt,
                effectiveEnd: effectiveEnd,
                content: .init(
                    encoding: content.encoding == .identity ? .identity : .zstd,
                    storedByteCount: Int64(content.storedByteCount),
                    storedSHA256: content.storedSHA256,
                    sourceByteCount: Int64(content.sourceByteCount),
                    sourceSHA256: content.sourceSHA256
                ),
                targets: targets.map { .init(consentId: $0.consentID.uuidString.lowercased(), outputFullUrls: $0.outputFullURLs) }
            ))
        } catch {
            throw ServerError.badRequest("Invalid recording transfer declaration")
        }
        self.content = content
        self.attachmentPath = attachmentPath
        intent = try ClinicalEventIntent(targets: commitment.intent.targets)
        output = .init(
            fullURL: outputFullURL,
            profile: profile,
            measurementBounds: try .init(start: commitment.declaration.effectiveAt, end: commitment.declaration.effectiveEnd),
            codeSystem: FHIRRecordingProjection.formatSystem,
            code: format.rawValue,
            sourceTypeIdentifier: sourceTypeIdentifier,
            awaitsContentVerification: true
        )
        serialized = String(decoding: commitment.serialized, as: UTF8.self)
        sha256 = commitment.sha256
    }

    init(restoring serialized: String, digest: String) throws {
        do {
            let commitment = try RecordingTransferCommitment(restoring: Data(serialized.utf8), sha256: digest)
            try self.init(commitment.declaration)
        } catch {
            throw ServerError.internalServerError("Retained recording declaration is unavailable")
        }
    }
}
