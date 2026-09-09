//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import OpenAPIRuntime
import Testing
@testable import TroveServer


struct BoundedRequestBodyTests {
    @Test(arguments: [HTTPBody.Length.known(4), .unknown])
    func preservesSlicedBytesAndEmptyChunksAtLimit(length: HTTPBody.Length) async throws {
        let bytes: [UInt8] = [99, 0, 255, 13, 10, 99]
        let stream = AsyncStream<HTTPBody.ByteChunk> { continuation in
            continuation.yield(bytes[1..<3])
            continuation.yield([])
            continuation.yield(bytes[3..<5])
            continuation.finish()
        }
        let result = try await BoundedRequestBody.collect(HTTPBody(stream, length: length), upTo: 4)
        #expect(result == Data([0, 255, 13, 10]))
    }

    @Test(arguments: [HTTPBody.Length.known(0), .unknown])
    func acceptsEmptyBodyWithZeroBudget(length: HTTPBody.Length) async throws {
        #expect(try await BoundedRequestBody.collect(HTTPBody(Data(), length: length), upTo: 0).isEmpty)
    }

    @Test
    func declaredOverflowDoesNotReadTheBody() async {
        let stream = AsyncThrowingStream<HTTPBody.ByteChunk, any Error>(unfolding: {
            Issue.record("Oversized declared input must not be consumed")
            return nil
        })
        await #expect(throws: BoundedRequestBody.ReadError.tooLarge) {
            try await BoundedRequestBody.collect(HTTPBody(stream, length: .known(Int64.max)), upTo: 4)
        }
    }

    @Test(arguments: [HTTPBody.Length.known(4), .unknown])
    func streamedOverflowIsDetectedEvenWithUnderreportedLength(length: HTTPBody.Length) async {
        let stream = AsyncStream<HTTPBody.ByteChunk> { continuation in
            continuation.yield([0, 1, 2, 3])
            continuation.yield([4])
            continuation.finish()
        }
        await #expect(throws: BoundedRequestBody.ReadError.tooLarge) {
            try await BoundedRequestBody.collect(HTTPBody(stream, length: length), upTo: 4)
        }
    }

    @Test(arguments: [-1, 0, 2])
    func inconsistentLengthIsNotReportedAsOverflow(length: Int64) async {
        await #expect(throws: BoundedRequestBody.ReadError.lengthMismatch) {
            try await BoundedRequestBody.collect(HTTPBody([1], length: .known(length)), upTo: 4)
        }
    }

    @Test
    func transportFailureAfterPrefixIsPreserved() async {
        let stream = AsyncThrowingStream<HTTPBody.ByteChunk, any Error> { continuation in
            continuation.yield([1, 2])
            continuation.finish(throwing: URLError(.networkConnectionLost))
        }
        await #expect(throws: URLError(.networkConnectionLost)) {
            try await BoundedRequestBody.collect(HTTPBody(stream, length: .unknown), upTo: 4)
        }
    }

    @Test
    func cancellationBeforeReadingDoesNotConsumeBody() async {
        let stream = AsyncThrowingStream<HTTPBody.ByteChunk, any Error>(unfolding: {
            Issue.record("Cancelled operation must not start reading")
            return nil
        })
        let task = Task { @concurrent in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await BoundedRequestBody.collect(HTTPBody(stream, length: .unknown), upTo: 4)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test(arguments: [false, true])
    func cancellationCannotReturnACompleteLookingPrefix(endsNormally: Bool) async {
        let body = HTTPBody(CancellingBytes(endsNormally: endsNormally), length: .unknown, iterationBehavior: .single)
        let task = Task { @concurrent in
            try await BoundedRequestBody.collect(body, upTo: 4)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}


extension BoundedRequestBodyTests {
    /// Cancels deterministically on the second read, without sleeps or cancelling the test task.
    private struct CancellingBytes: AsyncSequence, AsyncIteratorProtocol, Sendable {
        typealias Element = HTTPBody.ByteChunk

        let endsNormally: Bool
        private var reads = 0

        init(endsNormally: Bool) {
            self.endsNormally = endsNormally
        }

        func makeAsyncIterator() -> Self { self }

        mutating func next() async -> Element? {
            reads += 1
            guard reads == 1 else {
                withUnsafeCurrentTask { $0?.cancel() }
                return endsNormally ? nil : [2]
            }
            return [1]
        }
    }
}
