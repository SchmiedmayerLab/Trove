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
import GroveSensorKitFHIR
import OpenAPIRuntime


extension RecordingContentVerification {
    /// Native payloads spool to owned files. Grammar validation reuses Grove's format-specific limits;
    /// JSON and PPG decoding currently materialize at most the shared 64 MiB ceiling.
    static func native(
        _ body: HTTPBody, declaration: RecordingTransferDeclaration, format: RegisteredRecordingFormat, maximumWindowByteCount: Int
    ) async throws -> Self {
        let content = declaration.content
        let stored = try await storedFile(body, maximumByteCount: content.storedByteCount)
        guard stored.byteCount == content.storedByteCount,
              try digest(stored).sha256 == content.storedSHA256 else { throw FHIRValidationClient.invalid }
        let source: RecordingFile
        switch content.encoding {
        case .identity: source = stored
        case .zstd:
            source = try stored.zstandardDecompressed(byteCount: content.sourceByteCount, maximumWindowByteCount: maximumWindowByteCount)
        }
        guard source.byteCount == content.sourceByteCount else { throw FHIRValidationClient.invalid }
        let hashes = try digest(source)
        guard hashes.sha256 == content.sourceSHA256 else { throw FHIRValidationClient.invalid }
        try format.validatePayload(source, maximumByteCount: content.sourceByteCount)
        // Native object fields retain their own timing; the source-envelope period is checked separately.
        return Self(bounds: RecordingRouteBounds(), attachmentSHA1: hashes.sha1)
    }

    private static func storedFile(_ body: HTTPBody, maximumByteCount: Int) async throws -> RecordingFile {
        do {
            return try await RecordingFile.stage(chunks: body, maximumByteCount: Int64(maximumByteCount))
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw CancellationError() }
            if let fileError = error as? RecordingFile.FileError,
               [.byteLimitExceeded, .emptySource, .invalidByteLimit].contains(fileError) { throw FHIRValidationClient.invalid }
            if error is BoundedObjectStorageBody.StreamError { throw FHIRValidationClient.invalid }
            throw ServerError(status: .serviceUnavailable, title: "Recording Unavailable", detail: "Retry the unchanged record")
        }
    }

    private static func digest(_ file: RecordingFile) throws -> (sha256: String, sha1: Data) {
        var sha256 = SHA256(), sha1 = Insecure.SHA1()
        try file.readChunks { bytes in
            sha256.update(data: bytes)
            sha1.update(data: bytes)
        }
        return (sha256.finalize().map { String(format: "%02x", $0) }.joined(), Data(sha1.finalize()))
    }
}
