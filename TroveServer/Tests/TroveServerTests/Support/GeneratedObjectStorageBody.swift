//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import OpenAPIRuntime


struct GeneratedObjectStorageBody: AsyncSequence, Sendable {
    typealias Element = HTTPBody.ByteChunk

    struct AsyncIterator: AsyncIteratorProtocol {
        var remaining: Int

        mutating func next() async throws -> Element? {
            try Task.checkCancellation()
            guard remaining > 0 else {
                return nil
            }
            let bytes = GeneratedObjectStorageBody.chunk.prefix(Swift.min(remaining, GeneratedObjectStorageBody.chunk.count))
            remaining -= bytes.count
            return bytes
        }
    }

    static let chunk = ArraySlice([UInt8](repeating: 0xA5, count: 64 * 1024))

    let byteCount: Int

    var body: HTTPBody { HTTPBody(self, length: .known(Int64(byteCount)), iterationBehavior: .single) }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(remaining: byteCount) }

    func digest() async throws -> String {
        var hash = SHA256()
        for try await chunk in self { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
