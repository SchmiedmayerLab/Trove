//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

/// Cancels only the caller's wait, not AppAuth's refresh shared with other token requests.
enum KeycloakTokenRequest {
    typealias Completion = @Sendable (Result<String, any Error>) -> Void

    @MainActor
    static func value(start: (@escaping Completion) -> Void) async throws -> String {
        try Task.checkCancellation()
        // One buffered result preserves synchronous SDK completions. Stream cancellation releases
        // the waiter without a custom continuation lock or an unowned background task.
        let response = AsyncStream<Result<String, any Error>>.makeStream(bufferingPolicy: .bufferingOldest(1))
        defer { response.continuation.finish() }
        start { result in
            response.continuation.yield(result)
            response.continuation.finish()
        }
        var iterator = response.stream.makeAsyncIterator()
        guard let result = await iterator.next() else {
            throw CancellationError()
        }
        try Task.checkCancellation()
        return try result.get()
    }
}
