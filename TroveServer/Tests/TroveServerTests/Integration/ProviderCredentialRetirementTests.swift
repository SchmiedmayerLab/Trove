//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import SQLKit
import Testing
@testable import TroveServer


struct ProviderCredentialRetirementTests {
    @Test
    func currentDemandRetainsCredentialsAndRevocationRetiresOnlyReusableSecrets() async throws {
        try await TestApp.withApp { app, _ in
            let prepared = try await ProviderIngestionFixture.prepare(on: app, authorization: .init())
            let original = try await ProviderSQL.connection(prepared.connection.id, on: app.db)
            let now = Date()
            let sql = try ProviderSQL.sql(app.db)
            let retirement = ProviderCredentialRetirement(
                database: app.db,
                registrationIDs: [prepared.connection.registrationID],
                worker: .init(issuer: "https://example.test/workers", clientID: "provider-worker", applicationRevision: "synthetic-revision"),
                retention: 0
            )
            try await sql.raw("UPDATE provider_connections SET dormant_until = \(bind: now.addingTimeInterval(-1))").run()
            try await retirement.run(now: now)
            let active = try await ProviderSQL.connection(prepared.connection.id, on: app.db)
            #expect(active.credentialEnvelope != nil)
            #expect(active.dormantUntil > now)
            let approved = try await ProviderRegistrationStore.requireApproved(prepared.connection.registrationID, on: app.db)
            try await ProviderRegistrationStore(database: app.db).configure(
                approved.configuration, approved: false, audit: ClinicalEventStoreTests.researcher.auditContext
            )
            try await retirement.run(now: now.addingTimeInterval(61))
            let retired = try await ProviderSQL.connection(prepared.connection.id, on: app.db)
            #expect(retired.credentialEnvelope == nil)
            #expect(retired.sourceID == original.sourceID)
            #expect(retired.accountPseudonym == original.accountPseudonym)
            #expect(retired.accountEnvelope.ciphertext == original.accountEnvelope.ciphertext)
            #expect(retired.credentialVersion == original.credentialVersion)
            let audits = try await sql.raw("SELECT id FROM audit_events WHERE action = 'provider.credential.retired'").all()
            #expect(audits.count == 1)
        }
    }
}
