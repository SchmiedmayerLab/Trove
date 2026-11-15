//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import GroveFHIRContract
import GroveProviderFHIR
import SQLKit
import Testing
@testable import TroveServer
import Vapor


struct ProviderSharedIdentityTests {
    @Test("Two registrations retain one participant/provider identity and one verified-account scope")
    func registrationsShareIdentityWithoutSharingAuthority() async throws {
        try await TestApp.withApp { app, _ in
            try await ParticipantFixtures.createParticipant(on: app.db)
            let authorization = ProviderFixture.Authorization()
            let service = try ProviderFixture.service(on: app, authorization: authorization)
            let firstRegistration = try Self.ouraRegistration()
            let secondRegistration = try Self.ouraRegistration()
            for registration in [firstRegistration, secondRegistration] {
                try await ProviderRegistrationStore(database: app.db).configure(
                    registration, approved: true, audit: ClinicalEventStoreTests.researcher.auditContext
                )
            }
            let scope = ProviderGlobalScopeStore.Configuration(system: "https://deployment.example.org/provider-scope", value: "oura")
            try await ProviderGlobalScopeStore.configure(scope, on: app.db)
            let statuses = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                var values: [ProviderConnectionService.Status] = []
                for registration in [firstRegistration, secondRegistration] {
                    let intent = try await service.start(registrationID: registration.id, redirectID: "native")
                    values.append(try await service.complete(id: intent.id, state: ProviderFixture.state(intent), code: "synthetic"))
                }
                return values
            }
            #expect(statuses[0].id != statuses[1].id)
            #expect(statuses[0].sourceID == statuses[1].sourceID)
            let first = try await ProviderSQL.connection(statuses[0].id, on: app.db)
            let second = try await ProviderSQL.connection(statuses[1].id, on: app.db)
            #expect(first.accountPseudonym == second.accountPseudonym)
            let left = try await Self.record(connection: first, on: app)
            let right = try await Self.record(connection: second, on: app)
            #expect(left.sourceRecord == right.sourceRecord)
            #expect(left.outputFullURLs == right.outputFullURLs)
            #expect(left.json == right.json)
            try await Self.expectOtherParticipantIsDistinct(registration: firstRegistration, service: service, comparedWith: left, on: app)
            await #expect(throws: ProviderFailure.invalidConfiguration) {
                try await ProviderGlobalScopeStore.configure(.init(system: scope.system, value: "replacement"), on: app.db)
            }
            #expect(try await ProviderGlobalScopeStore.load(on: app.db) == scope.identifier())
        }
    }

    private static func expectOtherParticipantIsDistinct(
        registration: ProviderRegistration, service: ProviderConnectionService, comparedWith original: ExchangeRecord, on app: Application
    ) async throws {
        try await ParticipantFixtures.createParticipant(on: app.db, identityProviderId: "other-participant")
        let actor = AuthContext(
            issuer: TestApp.issuer, subject: "other-participant", email: "other@example.test",
            roles: [TestApp.participantRole], groups: [], researcherRole: TestApp.researcherRole, participantRole: TestApp.participantRole
        )
        let status = try await AuthContext.$current.withValue(actor) {
            let intent = try await service.start(registrationID: registration.id, redirectID: "native")
            return try await service.complete(id: intent.id, state: ProviderFixture.state(intent), code: "synthetic")
        }
        let connection = try await ProviderSQL.connection(status.id, on: app.db)
        let other = try await Self.record(connection: connection, on: app)
        #expect(original.sourceRecord != other.sourceRecord)
        #expect(original.outputFullURLs != other.outputFullURLs)
    }

    private static func record(connection: ProviderConnection, on app: Application) async throws -> ExchangeRecord {
        return try await app.db.transaction { transaction in
            let row = try #require(try await ProviderSQL.sql(transaction).raw("SELECT * FROM source_bindings WHERE id = \(bind: connection.sourceID)").first())
            let source = try SourceBinding(row: row)
            let identity = try await SourceIdentityKeyStore(keyring: TestApp.sourceKeyring()).recover(
                sourceID: source.id, participantID: source.participantID, on: transaction
            )
            let facts = try ProviderAcquisitionFacts(
                application: .init(name: "Trove", bundleIdentifier: "org.example.Trove", version: "1"),
                host: .init(operatingSystemName: "Linux", operatingSystemVersion: "6")
            )
            let date = Date(timeIntervalSince1970: 1_800_000_000)
            let context = try await ProviderConversionContext(
                producer: facts.producer(source: source, identity: identity),
                scope: ProviderGlobalScopeStore.scope(provider: .oura, connection: connection, source: source, on: transaction),
                instant: date.addingTimeInterval(60), sourceTimeZone: .gmt
            )
            return try #require(OuraFHIR.convert(.vo2Max(id: "same-global-native-id", timestamp: date, value: 45), context: context).record)
        }
    }

    private static func ouraRegistration() throws -> ProviderRegistration {
        .init(
            id: UUID(), provider: .oura, displayName: "Synthetic Oura", controller: "test-controller", region: "test-region",
            clientID: "synthetic-client", redirects: [.init(id: "native", uri: try #require(URL(string: "https://example.test/oauth/callback")))],
            scopes: ["personal", "daily"], sourceTokens: ["vO2_max"], supportsPKCE: true
        )
    }
}
