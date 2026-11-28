//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import OpenAPIRuntime
@testable import TroveServer


/// Adapter for small in-memory test doubles. Streaming behavior uses dedicated producers and S3 tests.
protocol BufferedTestObjectStorageProvider: ObjectStorageProvider {
    func uploadBuffered(data: Data, key: String, contentType: String) async throws
    func downloadBuffered(key: String, maximumBytes: Int) async throws -> Data
}


extension BufferedTestObjectStorageProvider {
    func upload(body: HTTPBody, key: String, contentType: String) async throws {
        try await uploadBuffered(data: Data(collecting: body, upTo: 50 * 1024 * 1024), key: key, contentType: contentType)
    }

    func downloadBody(key: String) async throws -> HTTPBody {
        try await HTTPBody(downloadBuffered(key: key, maximumBytes: 50 * 1024 * 1024))
    }

    /// Test stores that hold no derived artifacts list none.
    func keys(prefix: String) async throws -> [String] {
        []
    }
}
