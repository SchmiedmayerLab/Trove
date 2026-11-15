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


struct ProviderConnectionTests {
    @Test
    func reconnectKeepsSourceIdentityAndDifferentAccountsRequireExplicitDisconnect() async throws {
        try await TestApp.withApp { app, _ in
            try await ParticipantFixtures.createParticipant(on: app.db)
            let authorization = ProviderFixture.Authorization()
            let service = try ProviderFixture.service(on: app, authorization: authorization)
            let registration = try ProviderFixture.registration()
            try await ProviderRegistrationStore(database: app.db).configure(
                registration, approved: true, audit: ClinicalEventStoreTests.researcher.auditContext
            )
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let link = try await service.start(registrationID: registration.id, redirectID: "native")
                let state = try ProviderFixture.state(link)
                let first = try await service.complete(id: link.id, state: state, code: "synthetic-code")
                let replay = try await service.complete(id: link.id, state: state, code: "synthetic-code")
                #expect(replay.sourceID == first.sourceID)
                #expect(await authorization.exchanges == 1)
                _ = try await service.disconnect(id: first.id)
                let relink = try await service.start(registrationID: registration.id, redirectID: "native")
                let second = try await service.complete(id: relink.id, state: ProviderFixture.state(relink), code: "synthetic-new-code")
                #expect(first.id == second.id && first.sourceID == second.sourceID)
                #expect(second.generation > first.generation)
                await authorization.setAccount("456")
                let different = try await service.start(registrationID: registration.id, redirectID: "native")
                await #expect(throws: ProviderFailure.ambiguousAccount) {
                    try await service.complete(id: different.id, state: ProviderFixture.state(different), code: "synthetic-other-code")
                }
                _ = try await service.disconnect(id: second.id)
                let replacement = try await service.start(registrationID: registration.id, redirectID: "native")
                let third = try await service.complete(
                    id: replacement.id, state: ProviderFixture.state(replacement), code: "synthetic-replacement-code"
                )
                #expect(third.id != first.id && third.sourceID == first.sourceID)
                try await Self.expectOneWorkerSourceWithoutInstallations(on: app.db)
            }
        }
    }

    @Test
    func wrongStateAndUnknownExchangeCannotRedispatchCode() async throws {
        try await TestApp.withApp { app, _ in
            try await ParticipantFixtures.createParticipant(on: app.db)
            let authorization = ProviderFixture.Authorization()
            let service = try ProviderFixture.service(on: app, authorization: authorization)
            let registration = try ProviderFixture.registration()
            try await ProviderRegistrationStore(database: app.db).configure(
                registration, approved: true, audit: ClinicalEventStoreTests.researcher.auditContext
            )
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                let link = try await service.start(registrationID: registration.id, redirectID: "native")
                await #expect(throws: ProviderFailure.invalidLink) {
                    try await service.complete(id: link.id, state: String(repeating: "x", count: 43), code: "synthetic-code")
                }
                #expect(await authorization.exchanges == 0)
                await authorization.setExchangeFailure()
                await #expect(throws: ProviderFailure.unavailable) {
                    try await service.complete(id: link.id, state: ProviderFixture.state(link), code: "synthetic-code")
                }
                await #expect(throws: ProviderFailure.reauthorizationRequired) {
                    try await service.complete(id: link.id, state: ProviderFixture.state(link), code: "synthetic-code")
                }
                #expect(await authorization.exchanges == 1)
            }
        }
    }
    @Test
    func googleAuthorizationUsesOneExplicitOfflineGrantAndPKCEChallenge() async throws {
        try await TestApp.withApp { app, _ in
            try await ParticipantFixtures.createParticipant(on: app.db)
            let service = try ProviderFixture.service(on: app, authorization: .init())
            let registration = ProviderRegistration(
                id: UUID(), provider: .googleHealthAPI, displayName: "Synthetic Google", controller: "test-controller", region: "test-region",
                clientID: "synthetic-client", redirects: [.init(id: "native", uri: try #require(URL(string: "https://example.test/oauth/callback")))],
                scopes: ["https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly"],
                sourceTokens: ["weight"], supportsPKCE: true
            )
            try await ProviderRegistrationStore(database: app.db).configure(
                registration, approved: true, audit: ClinicalEventStoreTests.researcher.auditContext
            )
            let link = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                try await service.start(registrationID: registration.id, redirectID: "native")
            }
            let items = try #require(URLComponents(url: link.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems)
            #expect(Set(items.map(\.name)).count == items.count)
            #expect(items.first(where: { $0.name == "access_type" })?.value == "offline")
            #expect(items.first(where: { $0.name == "prompt" })?.value == "consent")
            #expect(items.first(where: { $0.name == "code_challenge_method" })?.value == "S256")
            #expect(items.first(where: { $0.name == "code_challenge" })?.value?.count == 43)
        }
    }

    private static func expectOneWorkerSourceWithoutInstallations(on database: any Database) async throws {
        let sql = try #require(database as? any SQLDatabase)
        let sources = try #require(try await sql.raw("SELECT COUNT(*) AS count FROM source_bindings WHERE kind = 'server-worker'").first())
        #expect(try sources.decode(column: "count", as: Int.self) == 1)
        let installations = try #require(try await sql.raw("SELECT COUNT(*) AS count FROM source_installations").first())
        #expect(try installations.decode(column: "count", as: Int.self) == 0)
    }

}
