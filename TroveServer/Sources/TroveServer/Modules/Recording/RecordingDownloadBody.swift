//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import GroveFHIRContract
import OpenAPIRuntime


/// Pulls only one bounded file chunk per transport request. The body owns the anonymous snapshot.
struct RecordingDownloadBody: AsyncSequence, Sendable {
    typealias Element = HTTPBody.ByteChunk

    struct AsyncIterator: AsyncIteratorProtocol, Sendable {
        var reader: RecordingFile.ChunkReader

        @concurrent
        mutating func next() async throws -> Element? {
            try reader.readNextChunk().map { ArraySlice($0) }
        }
    }

    let file: RecordingFile

    var body: HTTPBody { HTTPBody(self, length: .known(Int64(file.byteCount)), iterationBehavior: .single) }

    func makeAsyncIterator() -> AsyncIterator { .init(reader: file.makeChunkReader()) }
}
