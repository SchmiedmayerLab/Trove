//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import OpenAPIRuntime


final class InMemoryObjectStorageProvider: ObjectStorageProvider, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    private let lock = NSLock()

    func upload(body: HTTPBody, key: String, contentType: String) async throws {
        let data = try await Data(collecting: body, upTo: Int(Int32.max))
        try Task.checkCancellation()
        lock.withLock { storage[key] = data }
    }

    func downloadBody(key: String) async throws -> HTTPBody {
        let value = lock.withLock { storage[key] }
        guard let value else {
            throw ServerError.notFound("Object not found: \(key)")
        }
        return HTTPBody(value)
    }

    func keys(prefix: String) async throws -> [String] {
        lock.withLock { storage.keys.filter { $0.hasPrefix(prefix) } }
    }

    func ensureBucketExists() async throws {}

    func delete(key: String) async throws {
        _ = lock.withLock { storage.removeValue(forKey: key) }
    }

    func shutdown() async throws {}
}
