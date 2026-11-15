//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import NIOCore
import OpenAPIRuntime


/// Limits how far an upload body runs ahead of the storage connection's event loop.
///
/// AsyncHTTPClient hands each request body chunk to the connection's event loop and pauses the body only once that
/// loop has written enough to fill the connection's write buffer. While the loop is busy, a faster producer would keep
/// queueing chunks for it, up to the whole object. Before each pull, this sequence submits a marker to the loop, which
/// runs tasks in submission order: a completed marker means the loop has taken every chunk pulled before it. Waiting
/// for the marker from ``window`` pulls back keeps no more than ``window`` earlier chunks queued ahead of the connection,
/// while a short wait on the loop does not stall every chunk.
struct EventLoopPacedBody: AsyncSequence, Sendable {
    typealias Element = HTTPBody.ByteChunk

    struct AsyncIterator: AsyncIteratorProtocol {
        var base: HTTPBody.AsyncIterator
        let eventLoop: any EventLoop
        var markers: [EventLoopFuture<Void>] = []

        mutating func next() async throws -> Element? {
            markers.append(eventLoop.submit {})
            if markers.count > EventLoopPacedBody.window {
                try await markers.removeFirst().get()
            }
            return try await base.next()
        }
    }

    /// About 1 MiB of 64 KiB chunks, the size Soto signs and sends.
    static let window = 16

    let base: HTTPBody
    let eventLoop: any EventLoop

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator(), eventLoop: eventLoop)
    }
}
