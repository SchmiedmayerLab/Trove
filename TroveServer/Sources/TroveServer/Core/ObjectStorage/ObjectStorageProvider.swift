//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import OpenAPIRuntime


protocol ObjectStorageProvider: Sendable {
    func upload(body: HTTPBody, key: String, contentType: String) async throws
    func downloadBody(key: String) async throws -> HTTPBody
    /// Idempotent for an absent object; failures must not be reported as successful deletion.
    func delete(key: String) async throws

    /// Every key that starts with `prefix`, in any order.
    func keys(prefix: String) async throws -> [String]

    func ensureBucketExists() async throws

    func shutdown() async throws
}


extension ObjectStorageProvider {
    func upload(data: Data, key: String, contentType: String) async throws {
        try await upload(body: HTTPBody(data), key: key, contentType: contentType)
    }

    func download(key: String, maximumBytes: Int = 50 * 1024 * 1024) async throws -> Data {
        do {
            let body = try await downloadBody(key: key)
            return try await Data(collecting: BoundedObjectStorageBody.wrap(body, maximumBytes: maximumBytes), upTo: maximumBytes)
        } catch BoundedObjectStorageBody.StreamError.byteLimitExceeded {
            throw ServerError.internalServerError("Stored object exceeds the read limit")
        }
    }
}
