//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


final class InMemoryObjectStorageProvider: ObjectStorageProvider, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    private let lock = NSLock()

    func upload(data: Data, key: String, contentType: String) async throws {
        lock.withLock { storage[key] = data }
    }

    func download(key: String, maximumBytes: Int) async throws -> Data {
        let value = lock.withLock { storage[key] }
        guard let value else {
            throw ServerError.notFound("Object not found: \(key)")
        }
        guard value.count <= maximumBytes else { throw ServerError.internalServerError("Stored object exceeds the read limit") }
        return value
    }

    func ensureBucketExists() async throws {}

    func delete(key: String) async throws {
        _ = lock.withLock { storage.removeValue(forKey: key) }
    }

    func shutdown() async throws {}
}
