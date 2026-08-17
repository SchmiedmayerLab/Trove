//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
@testable import TroveServer


final class InMemoryObjectStorageProvider: ObjectStorageProvider, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    private let lock = NSLock()

    func upload(data: Data, key: String, contentType: String) async throws {
        lock.withLock { storage[key] = data }
    }

    func download(key: String) async throws -> Data {
        let value = lock.withLock { storage[key] }
        guard let value else {
            throw ServerError.notFound("Object not found: \(key)")
        }
        return value
    }

    func ensureBucketExists() async throws {}

    func shutdown() async throws {}
}
