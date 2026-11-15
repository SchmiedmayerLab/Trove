//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SQLKit
import Testing
@testable import TroveServer


struct RecordingDeclarationRecoveryTests {
    @Test
    func retainedDeclarationRestoresExactCommitmentAndRejectsCorruptionOrUnknownVersions() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await RecordingTransferHTTPTests.prepare(on: app)
            let original = try RecordingTransferDeclaration(RecordingTransferHTTPTests.declaration(fixture))
            let recovered = try RecordingTransferDeclaration(restoring: original.serialized, digest: original.sha256)
            #expect(recovered.serialized == original.serialized && recovered.sha256 == original.sha256)
            #expect(recovered.intent.serialized == original.intent.serialized)
            #expect(recovered.content.sourceSHA256 == original.content.sourceSHA256)
            #expect(throws: (any Error).self) {
                try RecordingTransferDeclaration(restoring: original.serialized + " ", digest: original.sha256)
            }
            var unknown = try #require(JSONSerialization.jsonObject(with: Data(original.serialized.utf8)) as? [String: Any])
            unknown["version"] = 2
            let bytes = try JSONSerialization.data(withJSONObject: unknown, options: [.sortedKeys, .withoutEscapingSlashes])
            #expect(throws: (any Error).self) {
                try RecordingTransferDeclaration(restoring: String(decoding: bytes, as: UTF8.self), digest: ArtifactStore.digest(bytes))
            }
        }
    }

    @Test
    func failedRegistrationAuditRollsBackTheDeclaration() async throws {
        try await TestApp.withApp { app, _ in
            let fixture = try await RecordingTransferHTTPTests.prepare(on: app)
            let declaration = try RecordingTransferDeclaration(RecordingTransferHTTPTests.declaration(fixture))
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("DROP TABLE audit_events").run()
            await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                await #expect(throws: (any Error).self) {
                    try await app.grove[RecordingTransferService.self].register(
                        sourceID: fixture.source.id, transferID: UUID(), declaration: declaration, installation: fixture.installation
                    )
                }
            }
            try await RecordingTransferHTTPTests.expectRows(transfers: 0, attempts: 0, receipts: 0, on: app)
        }
    }
}
