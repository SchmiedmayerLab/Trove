//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import Grove
import OpenAPIRuntime


final class ObjectStorageService: Module, @unchecked Sendable {
    private let provider: any ObjectStorageProvider

    init(provider: any ObjectStorageProvider) {
        self.provider = provider
    }

    func upload(data: Data, key: String, contentType: String) async throws {
        try await provider.upload(data: data, key: key, contentType: contentType)
    }

    func upload(body: HTTPBody, key: String, contentType: String) async throws {
        try await provider.upload(body: body, key: key, contentType: contentType)
    }

    func download(key: String, maximumBytes: Int = 50 * 1024 * 1024) async throws -> Data {
        guard maximumBytes > 0, maximumBytes <= 50 * 1024 * 1024 else {
            throw ServerError.badRequest("Unsupported artifact read limit")
        }
        return try await provider.download(key: key, maximumBytes: maximumBytes)
    }

    func downloadBody(key: String, maximumBytes: Int) async throws -> HTTPBody {
        guard (1...Int(Int32.max)).contains(maximumBytes) else {
            throw ServerError.badRequest("Unsupported artifact read limit")
        }
        return try BoundedObjectStorageBody.wrap(try await provider.downloadBody(key: key), maximumBytes: maximumBytes)
    }

    /// Finishes reading and checking the stored bytes before a caller can make an artifact ready.
    func verify(key: String, byteCount: Int, digest: String) async throws {
        var hasher = SHA256()
        var count = 0
        do {
            let body = try await downloadBody(key: key, maximumBytes: byteCount)
            for try await chunk in body {
                hasher.update(data: chunk)
                count += chunk.count
            }
        } catch BoundedObjectStorageBody.StreamError.byteLimitExceeded {
            throw ServerError.conflict("Stored artifact does not match the submitted bytes")
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard count == byteCount, actual == digest else {
            throw ServerError.conflict("Stored artifact does not match the submitted bytes")
        }
        try Task.checkCancellation()
    }

    func delete(key: String) async throws {
        try await provider.delete(key: key)
    }

    func ensureBucketExists() async throws {
        try await provider.ensureBucketExists()
    }

    func shutdown() async throws {
        try await provider.shutdown()
    }
}
