//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Fluent
import FluentPostgresDriver
import Foundation
import GroveFHIRContract
import SQLKit
import Testing
@testable import TroveServer


extension DatabaseRuntimePrivilegesTests {
    @Test
    func actualRuntimeCanProvisionAndRecoverIdentity() async throws {
        try await Self.withRuntime { fixture in
            let identity = try await Self.registerIdentity(on: fixture.database)
            let store = SourceIdentityKeyStore(keyring: try .init(currentKeyID: "current", keys: ["current": SymmetricKey(size: .bits256)]))
            let created = try await fixture.database.transaction { try await store.provision(context: identity, on: $0) }
            let recovered = try await fixture.database.transaction {
                try await store.recover(sourceID: identity.sourceID, participantID: identity.participantID, on: $0)
            }
            #expect(created.key == recovered.key)
            let sql = try #require(fixture.database as? any SQLDatabase)
            for table in CreateSourceIdentityKeys.tables {
                for operation in ["UPDATE \(table) SET source_id = source_id", "DELETE FROM \(table)", "TRUNCATE \(table) CASCADE"] {
                    await #expect {
                        try await sql.raw(SQLQueryString(operation)).run()
                    } throws: { ($0 as? PSQLError)?.serverInfo?[.sqlState] == "42501" }
                }
            }
            try await DatabaseRuntimePrivileges.validate(on: fixture.database)
        }
    }
}


extension DatabaseRuntimePrivilegesTests {
    private static func registerIdentity(on database: any Database) async throws -> SourceIdentityKeyContext {
        _ = try await ParticipantFixtures.createParticipant(on: database)
        let context = AuthContext(
            issuer: TestApp.issuer,
            subject: "test-participant",
            email: "participant@example.test",
            roles: [TestApp.participantRole],
            groups: [],
            researcherRole: TestApp.researcherRole,
            participantRole: TestApp.participantRole
        )
        let binding = try await AuthContext.$current.withValue(context) {
            try await SourceBindingFixture.unprovisioned(on: database)
        }
        return try SourceIdentityKeyContext(
            owner: (binding.participantID, binding.id),
            keyID: binding.keyID,
            epoch: KeyEpoch(1),
            identifierRoot: binding.identifierRoot,
            repository: BusinessIdentifier(system: IdentifierSystem(binding.identifierRoot + "/repository"), value: "healthkit")
        )
    }
}
