//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Testing
@testable import TroveServer


struct RecordingDownloadConfigurationTests {
    @Test
    func explicitDownloadBudgetAndDefaultArePreserved() throws {
        let storage = ObjectStorageService(provider: InMemoryObjectStorageProvider())
        #expect(try RecordingDownloadService(storage: storage).maximumByteCount == 512 * 1024 * 1024)
        #expect(try RecordingDownloadService(storage: storage, maximumByteCount: "123").maximumByteCount == 123)
    }

    @Test(arguments: ["", "0", "-1", "+1", " 1", "1 ", "1.5", "2147483648", "999999999999999999999999999"])
    func invalidBudgetsCannotSilentlyUseDefaults(value: String) {
        #expect(throws: (any Error).self) {
            try RecordingDownloadService(storage: ObjectStorageService(provider: InMemoryObjectStorageProvider()), maximumByteCount: value)
        }
    }
}
