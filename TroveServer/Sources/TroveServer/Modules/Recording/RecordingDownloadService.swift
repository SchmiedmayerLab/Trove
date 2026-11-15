//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import Grove
import GroveFHIRContract
import OpenAPIRuntime


/// Prepares exact immutable bytes for a caller that has already fenced study authority.
/// Preparation does not authorize disclosure; the caller must recheck authority and commit audit.
final class RecordingDownloadService: Module, Sendable {
    let storage: ObjectStorageService
    let maximumByteCount: Int

    init(storage: ObjectStorageService, maximumByteCount: String? = nil) throws {
        let raw = maximumByteCount ?? "536870912"
        guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }),
              let limit = Int(raw), (1...Int(Int32.max)).contains(limit) else {
            throw ServerError.internalServerError("Invalid recording download byte limit")
        }
        self.storage = storage
        self.maximumByteCount = limit
    }

    private static func hashes(_ file: RecordingFile) throws -> (sha256: String, sha1: Data) {
        var sha256 = SHA256(), sha1 = Insecure.SHA1()
        try file.readChunks { bytes in
            sha256.update(data: bytes)
            sha1.update(data: bytes)
        }
        return (sha256.finalize().map { String(format: "%02x", $0) }.joined(), Data(sha1.finalize()))
    }

    @concurrent
    func prepare(_ attachment: ClinicalRecordingAttachment) async throws -> RecordingFile {
        let content = attachment.declaration.content
        guard content.storedByteCount <= maximumByteCount, content.sourceByteCount <= maximumByteCount else {
            throw ServerError(status: .serviceUnavailable, title: "Recording Capacity Exceeded", detail: "Recording exceeds the download byte limit")
        }
        do {
            let body = try await storage.downloadBody(key: attachment.reference.key, maximumBytes: content.storedByteCount)
            let stored = try await RecordingFile.stage(chunks: body, maximumByteCount: Int64(content.storedByteCount))
            let storedHashes = try Self.hashes(stored)
            guard stored.byteCount == content.storedByteCount, storedHashes.sha256 == content.storedSHA256 else {
                throw FHIRValidationClient.invalid
            }
            let source = try content.encoding == .identity ? stored : stored.zstandardDecompressed(byteCount: content.sourceByteCount)
            let sourceHashes = try content.encoding == .identity ? storedHashes : Self.hashes(source)
            guard source.byteCount == content.sourceByteCount, sourceHashes.sha256 == content.sourceSHA256,
                  sourceHashes.sha1 == attachment.content.attachmentSHA1 else { throw FHIRValidationClient.invalid }
            try Task.checkCancellation()
            return source
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw CancellationError() }
            // Provider, disk and decoder diagnostics must not disclose source content or storage addresses.
            throw ServerError(status: .serviceUnavailable, title: "Recording Unavailable", detail: "Retry the recording download")
        }
    }
}
