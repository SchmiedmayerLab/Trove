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
import TroveAPIClient
@testable import TroveServer
import VaporTesting


struct SourceSetupRecoveryTests {
    @Test
    func lostRegistrationReplyRecoversWithoutAnotherSourceOrKeySetup() async throws {
        try await TestApp.withApp(token: .participant(subject: "setup-owner")) { app, token in
            try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: "setup-owner")
            let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("trove-source-setup-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("journal.sqlite")
            let scope = try EventDeliveryJournal.Scope(backend: Servers.Server1.url().absoluteString, issuer: TestApp.issuer, subject: "setup-owner")
            let journal = try EventDeliveryJournal(url: url, scope: scope, mode: .createNew)
            let pending = try await journal.createSource(localID: UUID(), queryDefinition: Data("heart-rate-v1".utf8))
            let transport = ReceiverClientTransport(application: app, token: token, loseRegistrationResponse: true)
            let client = try Client(serverURL: Servers.Server1.url(), configuration: .trove, transport: transport)
            await #expect(throws: SourceRegistration.RegistrationError.unavailable) {
                try await SourceRegistration.synchronize(
                    journal: journal, scope: scope, localID: pending.localID, client: client, validateSession: {}
                )
            }
            #expect(try await journal.sourceSetup(for: pending.localID) == pending)
            let request = try #require(await transport.registrationBodies.first)
            let object = try #require(JSONSerialization.jsonObject(with: request) as? [String: String])
            #expect(object == ["registrationID": pending.registrationID.uuidString.lowercased()])
            await journal.close()
            try await TestDatabase.withRestartedApplication(app) { reopened in
                try await configureServices(for: reopened, storageProvider: InMemoryObjectStorageProvider(), validator: .init(application: reopened))
                _ = try await TestApp.configureTransport(for: reopened)
                try await Self.restore(url: url, scope: scope, pending: pending, request: request, receiver: (reopened, token))
            }
        }
    }
}


extension SourceSetupRecoveryTests {
    private static func restore(
        url: URL, scope: EventDeliveryJournal.Scope, pending: EventDeliveryJournal.SourceSetup, request: Data, receiver: (Application, String?)
    ) async throws {
        let (app, token) = receiver
        let journal = try EventDeliveryJournal(url: url, scope: scope, mode: .openExisting)
        let setup = try await journal.sourceSetup(for: pending.localID)
        #expect(setup == pending)
        let transport = ReceiverClientTransport(application: app, token: token)
        let client = try Client(serverURL: Servers.Server1.url(), configuration: .trove, transport: transport)
        let confirmed = try await SourceRegistration.synchronize(
            journal: journal, scope: scope, localID: setup.localID, client: client, validateSession: {}
        )
        let binding = try #require(confirmed.binding)
        #expect(await transport.registrationBodies == [request])
        let sourceID = try #require(UUID(uuidString: binding.id))
        let identity = try await journal.identityScope(for: sourceID)
        #expect(identity.keyID == setup.localID.uuidString.lowercased())
        #expect(identity.systems == (try binding.pseudonymousIdentifierSystems.groveSystems()))
        let checkpoint = try await journal.checkpoint(for: sourceID)
        #expect(checkpoint.cursor == nil)
        let sql = try #require(app.db as? any SQLDatabase)
        let counts = try await sql.raw("SELECT count(*) AS count FROM source_bindings").all()
        #expect(try counts.first?.decode(column: "count", as: Int.self) == 1)
        let audits = try await sql.raw("SELECT count(*) AS count FROM audit_events WHERE action = 'source.registered'").all()
        #expect(try audits.first?.decode(column: "count", as: Int.self) == 1)
        await journal.close()
    }
}
