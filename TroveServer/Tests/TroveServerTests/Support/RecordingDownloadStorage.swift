//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
@testable import TroveServer


/// Small deterministic storage double; large streaming behavior requires separate evidence.
actor RecordingDownloadStorage: BufferedTestObjectStorageProvider {
    private let storage = InMemoryObjectStorageProvider()
    private var action: (@Sendable () async throws -> Void)?
    private(set) var reads = 0

    func reset(afterRead action: (@Sendable () async throws -> Void)? = nil) {
        reads = 0
        self.action = action
    }

    func uploadBuffered(data: Data, key: String, contentType: String) async throws {
        try await storage.upload(data: data, key: key, contentType: contentType)
    }

    func downloadBuffered(key: String, maximumBytes: Int) async throws -> Data {
        reads += 1
        let bytes = try await storage.download(key: key, maximumBytes: maximumBytes)
        let action = self.action
        self.action = nil
        try await action?()
        return bytes
    }

    func delete(key: String) async throws { try await storage.delete(key: key) }
    func ensureBucketExists() {}
    func shutdown() {}
}
