//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
@testable import TroveServer
import Vapor


struct EventLoopPacedBodyTests {
    @Test
    func pullsAtMostItsWindowWhileTheEventLoopIsBusy() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = group.next()
        let window = EventLoopPacedBody.window
        let source = ObjectStorageStreamSource(Array(repeating: "ab", count: 4 * window))
        // Stand in for a storage connection whose event loop has not yet taken any queued chunk.
        let release = DispatchSemaphore(value: 0)
        eventLoop.execute { release.wait() }
        let reader = Task {
            var byteCount = 0
            for try await chunk in EventLoopPacedBody(base: source.body(), eventLoop: eventLoop) {
                byteCount += chunk.count
            }
            return byteCount
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while await source.reads < window, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        // Give a missing bound time to show.
        try await Task.sleep(for: .milliseconds(100))
        let readsWhileBusy = await source.reads
        release.signal()
        let byteCount = try await reader.value
        try await group.shutdownGracefully()
        #expect(readsWhileBusy == window)
        #expect(byteCount == 8 * window)
        // Every chunk and the end of the body.
        #expect(await source.reads == 4 * window + 1)
    }
}
