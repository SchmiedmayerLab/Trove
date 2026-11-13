//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Fluent
import Foundation
import GroveFHIRContract
import SQLKit
import Testing
import TroveAPIClient
@testable import TroveServer
import Vapor


/// Low-level storage tests deliberately start before key provisioning. Application tests use the service above.
enum SourceBindingFixture {
    static func registerJournal(
        _ journal: EventDeliveryJournal, source: SourceBinding, query: Data, receiver: (Application, String?)
    ) async throws {
        let setup = try await journal.createSource(localID: UUID(), queryDefinition: query)
        let transport = ReceiverClientTransport(application: receiver.0, token: receiver.1)
        let client = try Client(serverURL: Servers.Server1.url(), configuration: .trove, transport: transport)
        let confirmed = try await SourceRegistration.synchronize(
            journal: journal, scope: journal.scope, localID: setup.localID, client: client, validateSession: {}
        )
        #expect(confirmed.binding?.source.id == source.id.uuidString.lowercased())
        #expect(confirmed.binding?.source.keyID == source.keyID.uuidString.lowercased())
    }

    static func unprovisioned(on database: any Database) async throws -> SourceBinding {
        let context = try AuthContext.checkIsParticipant()
        return try await database.transaction { transaction in
            let participantID = try await SourceBindingService.lockParticipant(context, on: transaction)
            let sql = try #require(transaction as? any SQLDatabase)
            let id = UUID(), keyID = UUID()
            let root = context.issuer + "/trove/sources/" + id.uuidString.lowercased()
            let systems = try SourceIdentityNamespaces.assign(root: root, keyID: keyID)
            try await sql.raw("""
                INSERT INTO source_bindings (
                    id, participant_id, key_id, key_epoch, repository_kind, kind, identifier_root, event_identifier_system,
                    participant_identifier_system, participant_identifier_value, created_at
                ) VALUES (
                    \(bind: id), \(bind: participantID), \(bind: keyID), '1', 'healthkit', 'participant-app',
                    \(bind: root), \(bind: systems.recordVersion.rawValue), \(bind: context.issuer + "/trove/participants"),
                    \(bind: participantID.uuidString.lowercased()), \(bind: Date())
                )
                """)
                .run()
            let row = try #require(try await sql.raw("SELECT * FROM source_bindings WHERE id = \(bind: id)").first())
            return try SourceBinding(row: row)
        }
    }
}


extension SourceBindingService {
    /// Production registration with a reproducible synthetic installation credential for retry fixtures.
    func registerSource(registrationID: UUID, repositoryKind: SourceRepositoryKind = .healthKit) async throws -> SourceBinding {
        let bytes = Data(SHA256.hash(data: Data(registrationID.uuidString.utf8)))
        return try await SourceInstallationService(database: database, keyring: TestApp.sourceKeyring()).register(
            registrationID: registrationID,
            repositoryKind: repositoryKind,
            credential: SourceInstallationCredential(base64: bytes.base64EncodedString())
        ).source
    }
}
