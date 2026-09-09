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
import TroveAPIServer
@testable import TroveServer


struct StudyAuditDecodingTests {
    @Test(arguments: [
        ("unknown", "succeeded"), ("source.registered", "succeeded"),
        ("consent.recorded", "disclosure_intent"), ("study.audit.disclosure", "succeeded"),
        ("study.published", "unknown")
    ])
    func malformedStoredActionsAndOutcomesFailClosed(action: String, outcome: String) async throws {
        try await TestApp.withApp { app, _ in
            let sql = try #require(app.db as? any SQLDatabase)
            // Project invalid values without disabling the actual append-only/schema guards.
            let row = try #require(try await sql.raw("""
                SELECT \(bind: UUID()) AS id, \(bind: Date()) AS occurred_at,
                       'https://identity.example' AS actor_issuer, 'actor' AS actor_subject,
                       NULL AS initiator_issuer, NULL AS initiator_subject,
                       \(bind: action) AS action, \(bind: outcome) AS outcome,
                       \(bind: UUID()) AS target_id, NULL AS target_version,
                       \(bind: UUID()) AS correlation_id, NULL AS application_revision
                """)
                .first())
            #expect(throws: (any Error).self) { try StudyAuditRecord(row: row) }
        }
    }

    @Test(arguments: [
        AuditEvent.Action.sourceRegistered, .sourceRevoked, .clinicalEventAccepted,
        .clinicalEventAttributed, .clinicalEventReceiptDisclosure
    ])
    func sourceActionsCannotBeMappedIntoStudyResponses(action: AuditEvent.Action) {
        #expect(throws: AuditError.invalidScope) { try Components.Schemas.StudyAuditAction(action) }
    }

    @Test
    func everyPublishedStudyActionHasAnExactServerMapping() throws {
        let actions = AuditEvent.Action.allCases.filter { $0.scopeKind == .study }
        let mapped = try actions.map { try Components.Schemas.StudyAuditAction($0) }
        #expect(Set(mapped) == Set(Components.Schemas.StudyAuditAction.allCases))
        #expect(zip(actions, mapped).allSatisfy { $0.rawValue == $1.rawValue })
    }
}
