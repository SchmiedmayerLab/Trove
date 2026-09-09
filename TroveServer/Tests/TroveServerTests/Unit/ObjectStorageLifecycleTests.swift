//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
@testable import TroveServer
import Vapor


private actor LifecycleStorage: ObjectStorageProvider {
    private(set) var shutdownCompleted = false
    let fails: Bool

    init(fails: Bool) { self.fails = fails }
    func upload(data: Data, key: String, contentType: String) {}
    func download(key: String, maximumBytes: Int) -> Data { Data() }
    func delete(key: String) {}
    func ensureBucketExists() {}

    func shutdown() async throws {
        await Task.yield()
        shutdownCompleted = true
        if fails { throw ServerError.unexpectedError }
    }
}


struct ObjectStorageLifecycleTests {
    @Test(arguments: [false, true])
    func applicationShutdownAwaitsStorage(fails: Bool) async throws {
        let provider = LifecycleStorage(fails: fails)
        let app = try await Application.make(.testing)
        app.lifecycle.use(ObjectStorageLifecycle(storageService: .init(provider: provider)))
        try await app.asyncShutdown()
        #expect(await provider.shutdownCompleted)
    }
}
