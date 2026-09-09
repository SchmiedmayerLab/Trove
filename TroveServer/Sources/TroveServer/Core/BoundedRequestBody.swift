//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import OpenAPIRuntime


/// Preserves request bytes while keeping overflow distinguishable from a failed body read.
enum BoundedRequestBody {
    enum ReadError: Error, Equatable {
        case tooLarge
        case lengthMismatch
    }

    static func collect(_ body: HTTPBody, upTo maximumBytes: Int) async throws -> Data {
        precondition(maximumBytes >= 0)
        try Task.checkCancellation()
        if case .known(let length) = body.length {
            guard length >= 0 else { throw ReadError.lengthMismatch }
            guard length <= maximumBytes else { throw ReadError.tooLarge }
        }
        var bytes = Data()
        for try await chunk in body {
            try Task.checkCancellation()
            guard chunk.count <= maximumBytes - bytes.count else { throw ReadError.tooLarge }
            bytes.append(contentsOf: chunk)
        }
        // Some sequences end normally on cancellation. Their prefix is not a complete request.
        try Task.checkCancellation()
        if case .known(let length) = body.length, length != bytes.count {
            throw ReadError.lengthMismatch
        }
        return bytes
    }
}
