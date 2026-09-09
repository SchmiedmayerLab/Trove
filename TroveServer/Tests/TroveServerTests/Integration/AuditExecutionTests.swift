//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import HTTPTypes
import SQLKit
import Testing
@testable import TroveServer


struct AuditExecutionTests {
    private enum ProbeError: Error { case interrupted }

    @Test
    func concurrentAuthenticatedRequestsKeepDistinctServerOwnedAuditContext() async throws {
        try await TestApp.withApp { app, _ in
            let key = try SigningKeyFixtures.SigningKey(identifier: "audit-test")
            let token = try await key.token()
            let provider = try await KeycloakSigningKeys(initialJWKS: .init(keys: [key.jwk])) {
                throw ProbeError.interrupted
            }
            let middleware = AuthMiddleware(
                keyProvider: provider,
                tokenPolicy: try .init(issuer: TestApp.issuer, apiAudience: TestApp.apiAudience),
                researcherRole: TestApp.researcherRole,
                participantRole: TestApp.participantRole,
                logger: app.logger,
                auditConfiguration: try .init(applicationRevision: "revision-123")
            )
            let claimedCorrelation = UUID()
            async let first: Void = Self.request(middleware, token: token, claim: claimedCorrelation, on: app.db)
            async let second: Void = Self.request(middleware, token: token, claim: claimedCorrelation, on: app.db)
            _ = try await (first, second)
            let sql = try #require(app.db as? any SQLDatabase)
            let rows = try await sql.raw("""
                SELECT actor_issuer, actor_subject, application_revision, correlation_id, initiator_subject FROM audit_events
                """)
                .all()
            #expect(rows.count == 4)
            let correlations = try rows.map { try $0.decode(column: "correlation_id", as: UUID.self) }
            #expect(Set(correlations).count == 2)
            #expect(!correlations.contains(claimedCorrelation))
            for id in Set(correlations) { #expect(correlations.filter { $0 == id }.count == 2) }
            for row in rows {
                #expect(try row.decode(column: "actor_issuer", as: String.self) == TestApp.issuer)
                #expect(try row.decode(column: "actor_subject", as: String.self) == "refresh-participant")
                #expect(try row.decode(column: "application_revision", as: String.self) == "revision-123")
                #expect(try row.decode(column: "initiator_subject", as: String?.self) == nil)
            }
            #expect(AuthContext.current == nil)
        }
    }

    @Test
    func cleanupInvocationsHaveDistinctContextAndDoNotInventARevision() {
        let first = AuditEvent.Context.artifactCleanup()
        let second = AuditEvent.Context.artifactCleanup()
        #expect(first.correlationID != second.correlationID)
        #expect(first.applicationRevision == nil)
        #expect(first.initiator == nil)
    }

    @Test(arguments: ["", " ", "revision\nforged", "revision\0tail", "révision", String(repeating: "a", count: 129)])
    func malformedRevisionIsRejectedWithoutEchoingItsContents(revision: String) {
        #expect(throws: AuditConfiguration.Failure.invalidRevision) {
            try AuditConfiguration(applicationRevision: revision)
        }
    }
}


extension AuditExecutionTests {
    private static func request(_ middleware: AuthMiddleware, token: String, claim: UUID, on database: any Database) async throws {
        let correlationHeader = try #require(HTTPField.Name("X-Correlation-ID"))
        let revisionHeader = try #require(HTTPField.Name("X-Application-Revision"))
        let actorHeader = try #require(HTTPField.Name("X-Initiator-Subject"))
        let (response, _) = try await middleware.intercept(
            .init(method: .post, scheme: "https", authority: "api.example", path: "/protected", headerFields: [
                .authorization: "Bearer \(token)", correlationHeader: claim.uuidString,
                revisionHeader: "forged-revision", actorHeader: "forged-actor"
            ]),
            body: nil,
            metadata: .init(),
            operationID: "audit-fixture"
        ) { _, _, _ in
            let actor = try AuthContext.checkIsParticipant()
            try await database.transaction { transaction in
                for _ in 0..<2 {
                    let event = AuditEvent(
                        context: actor.auditContext,
                        action: .sourceRegistered,
                        scope: .participantSource(participantID: UUID(), sourceBindingID: UUID()),
                        target: .init(id: UUID())
                    )
                    try await AuditRepository.recordMutation(event, on: transaction)
                }
            }
            return (.init(status: .noContent), nil)
        }
        #expect(response.status == .noContent)
        #expect(AuthContext.current == nil)
    }
}
