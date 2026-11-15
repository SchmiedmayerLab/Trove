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
import OpenAPIRuntime


/// Adapts Grove's immutable snapshot to pull-based HTTP. No producer task or unbounded stream buffer is created.
struct RecordingUploadBody: AsyncSequence, Sendable {
    typealias Element = ArraySlice<UInt8>

    struct AsyncIterator: AsyncIteratorProtocol {
        var reader: RecordingFile.ChunkReader

        mutating func next() async throws -> Element? {
            guard let bytes = try reader.readNextChunk() else {
                return nil
            }
            return Array(bytes)[...]
        }
    }

    private let file: RecordingFile

    var body: HTTPBody { .init(self, length: .known(Int64(file.byteCount)), iterationBehavior: .multiple) }

    init(url: URL, byteCount: Int64, sha256: String) throws {
        file = try RecordingFile.stage(copying: url, maximumByteCount: byteCount)
        guard Int64(file.byteCount) == byteCount else { throw RecordingTransferDrainer.Failure.fileChanged }
        var digest = SHA256()
        try file.readChunks { digest.update(data: $0) }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw RecordingTransferDrainer.Failure.fileChanged
        }
    }

    func makeAsyncIterator() -> AsyncIterator { .init(reader: file.makeChunkReader()) }
}
