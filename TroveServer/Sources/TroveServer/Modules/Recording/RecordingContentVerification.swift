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
import GroveFoundation
import OpenAPIRuntime


/// Complete content evidence, not collection authority or clinical custody.
struct RecordingContentVerification: Sendable {
    let bounds: RecordingRouteBounds
    let attachmentSHA1: Data

    /// The caller authorizes storage access and supplies the retained declaration before reading.
    /// No output is returned until both representations, the complete CSV and the Zstandard frame match.
    static func verify(
        _ body: HTTPBody, declaration: RecordingTransferDeclaration, maximumWindowByteCount: Int
    ) async throws -> Self {
        guard declaration.output.code == RegisteredRecordingFormat.locationTrackSamples.rawValue else {
            throw FHIRValidationClient.invalid
        }
        do {
            var input = StoredReader(body: body, content: declaration.content)
            var source = try SourceReader(content: declaration.content)
            switch declaration.content.encoding {
            case .identity:
                while let chunk = try await input.next() { try source.read(chunk) }
            case .zstd:
                var decoder = try Zstd.StreamDecompressor(
                    compressedByteCount: Int64(declaration.content.storedByteCount),
                    decodedByteCount: Int64(declaration.content.sourceByteCount),
                    maximumWindowByteCount: maximumWindowByteCount
                )
                while let chunk = try await input.next() { try decoder.write(chunk) { try source.read($0) } }
                try decoder.finish()
            }
            try input.finish()
            let result = try source.finish()
            try Task.checkCancellation()
            return result
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw CancellationError() }
            if let error = error as? ServerError { throw error }
            // Parser and decoder diagnostics may contain source values.
            throw FHIRValidationClient.invalid
        }
    }
}


extension RecordingContentVerification {
    /// Retains the provider's current chunk; additional copies passed to the decoder are at most 64 KiB.
    private struct StoredReader {
        private var iterator: HTTPBody.AsyncIterator
        private var pending: HTTPBody.ByteChunk = []
        private var count = 0
        private var hasher = SHA256()
        private let content: RecordingTransferDeclaration.Content

        init(body: HTTPBody, content: RecordingTransferDeclaration.Content) {
            iterator = body.makeAsyncIterator()
            self.content = content
        }

        mutating func next() async throws -> Data? {
            try Task.checkCancellation()
            while pending.isEmpty {
                let chunk: HTTPBody.ByteChunk?
                do { chunk = try await iterator.next() } catch {
                    try Task.checkCancellation()
                    if error is CancellationError { throw CancellationError() }
                    if error is BoundedObjectStorageBody.StreamError { throw FHIRValidationClient.invalid }
                    throw ServerError(status: .serviceUnavailable, title: "Recording Unavailable", detail: "Retry the unchanged record")
                }
                guard let chunk else {
                    return nil
                }
                guard chunk.count <= content.storedByteCount - count else { throw FHIRValidationClient.invalid }
                count += chunk.count
                hasher.update(data: chunk)
                pending = chunk
                try Task.checkCancellation()
            }
            let chunk = pending.prefix(64 * 1024)
            pending = pending.dropFirst(chunk.count)
            return Data(chunk)
        }

        func finish() throws {
            guard count == content.storedByteCount,
                  hasher.finalize().map({ String(format: "%02x", $0) }).joined() == content.storedSHA256 else {
                throw FHIRValidationClient.invalid
            }
        }
    }

    private struct SourceReader {
        private var reader: RecordingCSVReader.Stream
        private var bounds = RecordingRouteBounds()
        private var count = 0
        private var hasher = SHA256()
        private var attachmentHasher = Insecure.SHA1()
        private let content: RecordingTransferDeclaration.Content

        init(content: RecordingTransferDeclaration.Content) throws {
            self.content = content
            let limits = RecordingCSVReader.Limits.default
            reader = try .init(format: .locationTrackSamples, limits: .init(
                maximumByteCount: content.sourceByteCount,
                maximumRecordByteCount: limits.maximumRecordByteCount,
                maximumFieldByteCount: limits.maximumFieldByteCount
            ))
        }

        mutating func read(_ bytes: Data) throws {
            guard bytes.count <= content.sourceByteCount - count else { throw FHIRValidationClient.invalid }
            count += bytes.count
            hasher.update(data: bytes)
            // R4 Attachment.hash is SHA-1; SHA-256 independently binds the source and stored representations.
            attachmentHasher.update(data: bytes)
            try reader.read(bytes) { try bounds.include($0) }
        }

        mutating func finish() throws -> RecordingContentVerification {
            try reader.finish()
            guard count == content.sourceByteCount,
                  hasher.finalize().map({ String(format: "%02x", $0) }).joined() == content.sourceSHA256 else {
                throw FHIRValidationClient.invalid
            }
            return .init(bounds: bounds, attachmentSHA1: Data(attachmentHasher.finalize()))
        }
    }
}
