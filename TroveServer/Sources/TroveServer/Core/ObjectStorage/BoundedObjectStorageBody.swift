//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import OpenAPIRuntime


/// Pulls one storage chunk at a time; declared lengths never replace the running byte limit.
struct BoundedObjectStorageBody: AsyncSequence, Sendable {
    typealias Element = HTTPBody.ByteChunk
    enum StreamError: Error { case byteLimitExceeded }

    struct AsyncIterator: AsyncIteratorProtocol {
        var source: HTTPBody.AsyncIterator
        var remaining: Int
        var finished = false

        mutating func next() async throws -> Element? {
            guard !finished else {
                return nil
            }
            do {
                try Task.checkCancellation()
                let next = try await source.next()
                try Task.checkCancellation()
                guard let chunk = next else {
                    finished = true
                    return nil
                }
                guard chunk.count <= remaining else {
                    throw StreamError.byteLimitExceeded
                }
                remaining -= chunk.count
                return chunk
            } catch {
                finished = true
                throw error
            }
        }
    }

    let source: HTTPBody
    let maximumBytes: Int

    static func wrap(_ body: HTTPBody, maximumBytes: Int) throws -> HTTPBody {
        guard maximumBytes >= 0 else { throw ServerError.badRequest("Unsupported object read limit") }
        if case .known(let count) = body.length, count < 0 || count > maximumBytes {
            throw StreamError.byteLimitExceeded
        }
        return HTTPBody(Self(source: body, maximumBytes: maximumBytes), length: body.length, iterationBehavior: .single)
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(source: source.makeAsyncIterator(), remaining: maximumBytes)
    }
}
