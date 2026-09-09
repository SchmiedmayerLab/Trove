//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


protocol ObjectStorageProvider: Sendable {
    func upload(data: Data, key: String, contentType: String) async throws
    func download(key: String, maximumBytes: Int) async throws -> Data
    /// Idempotent for an absent object; failures must not be reported as successful deletion.
    func delete(key: String) async throws

    func ensureBucketExists() async throws

    func shutdown() async throws
}
