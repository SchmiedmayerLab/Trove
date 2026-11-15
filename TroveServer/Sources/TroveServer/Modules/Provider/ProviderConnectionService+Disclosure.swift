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


extension ProviderConnectionService {
    func statuses() async throws -> [Status] {
        let actor = try AuthContext.checkIsParticipant()
        // swiftlint:disable:next first_where - Fluent query builder, not a Sequence
        let participant = try await Participant.query(on: database)
            .filter(\.$identityProviderIssuer == actor.issuer)
            .filter(\.$identityProviderId == actor.subject)
            .first()
        guard let participant else { throw ProviderFailure.fenced }
        let participantID = try participant.requireID()
        let rows = try await ProviderSQL.sql(database)
            .raw("""
                SELECT * FROM provider_connections WHERE participant_id = \(bind: participantID) ORDER BY created_at, id LIMIT 129
                """)
            .all()
        guard rows.count <= 128 else { throw ProviderFailure.capacityExceeded }
        var results: [Status] = []
        for row in rows {
            let connection = try ProviderConnection(row: row)
            let audit = AuditEvent(
                context: actor.auditContext,
                action: .providerStatusDisclosure,
                scope: .participantProvider(participantID: participantID, registrationID: connection.registrationID),
                target: .init(id: connection.id)
            )
            results.append(try await AuditRepository.disclose(audit, on: database) { _ in
                try await Self.status(connection, on: self.database)
            })
        }
        return results
    }
}
