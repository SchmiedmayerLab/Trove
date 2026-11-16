//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import OpenAPIRuntime


actor ObjectStorageStreamSource {
    enum Failure: Error { case interrupted }

    private let chunks: [HTTPBody.ByteChunk]
    private let failureAt: Int?
    private let cancellationAt: Int?
    private(set) var reads = 0

    init(_ chunks: [String], failureAt: Int? = nil, cancellationAt: Int? = nil) {
        self.chunks = chunks.map { ArraySlice($0.utf8) }
        self.failureAt = failureAt
        self.cancellationAt = cancellationAt
    }

    nonisolated func body(length: HTTPBody.Length = .unknown) -> HTTPBody {
        HTTPBody(AsyncThrowingStream(unfolding: { try await self.next() }), length: length)
    }

    private func next() throws -> HTTPBody.ByteChunk? {
        let index = reads
        reads += 1
        if index == cancellationAt { withUnsafeCurrentTask { $0?.cancel() } }
        if index == failureAt { throw Failure.interrupted }
        return index < chunks.count ? chunks[index] : nil
    }
}
