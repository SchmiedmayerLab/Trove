//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


protocol ObjectStorageProvider: Sendable {
    func upload(data: Data, key: String, contentType: String) async throws
    func download(key: String) async throws -> Data

    func ensureBucketExists() async throws

    func shutdown() async throws
}
