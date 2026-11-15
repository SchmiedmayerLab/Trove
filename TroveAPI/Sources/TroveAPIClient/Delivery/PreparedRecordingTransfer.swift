// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Crypto
import Foundation
import GroveFHIRContract
import TroveAPITypes


/// One immutable recording prepared for the existing journal and resumable transfer protocol.
/// The caller must authorize this exact output before preparation; this type grants no collection permission.
public struct PreparedRecordingTransfer: Sendable {
    public let recording: DeliveryRecording
    public let declaration: Components.Schemas.RecordingTransferDeclaration

    /// Compresses only when smaller, hashes bounded chunks, and retains the selected file through journal staging.
    /// The FHIR attachment still describes the original bytes, regardless of transport compression.
    public init(
        file: RecordingFile,
        attachmentPath: String,
        outputFullURL: String,
        profile: String,
        sourceTypeIdentifier: String,
        format: RegisteredRecordingFormat,
        effectiveAt: Date,
        effectiveEnd: Date,
        consentIDs: [UUID]
    ) throws {
        guard !consentIDs.isEmpty else {
            throw RecordingTransferCommitment.Failure.invalidDeclaration
        }
        let compressed = try file.zstandardCompressedIfSmaller(maximumByteCount: file.byteCount)
        let stored = compressed ?? file
        let sourceDigest = try Self.digest(file)
        let storedDigest = try compressed.map(Self.digest) ?? sourceDigest
        let declaration = Components.Schemas.RecordingTransferDeclaration(
            attachmentPath: attachmentPath,
            outputFullUrl: outputFullURL,
            profile: profile,
            sourceTypeIdentifier: sourceTypeIdentifier,
            format: format.rawValue,
            effectiveAt: effectiveAt,
            effectiveEnd: effectiveEnd,
            content: .init(
                encoding: compressed == nil ? .identity : .zstd,
                storedByteCount: Int64(stored.byteCount),
                storedSHA256: storedDigest,
                sourceByteCount: Int64(file.byteCount),
                sourceSHA256: sourceDigest
            ),
            targets: consentIDs.map { .init(consentId: $0.uuidString.lowercased(), outputFullUrls: [outputFullURL]) }
        )
        self.declaration = try RecordingTransferCommitment(declaration).declaration
        recording = DeliveryRecording(relativePath: attachmentPath, byteCount: stored.byteCount) { try stored.readChunks($0) }
    }

    private static func digest(_ file: RecordingFile) throws -> String {
        var hasher = SHA256()
        try file.readChunks { hasher.update(data: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
