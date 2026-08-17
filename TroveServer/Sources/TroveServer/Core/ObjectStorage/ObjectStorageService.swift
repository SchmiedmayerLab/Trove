//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Grove


final class ObjectStorageService: Module, @unchecked Sendable {
    private let provider: any ObjectStorageProvider

    init(provider: any ObjectStorageProvider) {
        self.provider = provider
    }

    func upload(data: Data, key: String, contentType: String) async throws {
        try await provider.upload(data: data, key: key, contentType: contentType)
    }

    func download(key: String) async throws -> Data {
        try await provider.download(key: key)
    }

    func ensureBucketExists() async throws {
        try await provider.ensureBucketExists()
    }

    func shutdown() async throws {
        try await provider.shutdown()
    }
}
