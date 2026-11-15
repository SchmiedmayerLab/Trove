//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation


extension ProviderConnectionService {
    /// Account-scoped native keys retain one pseudonym across independently authorized registrations.
    func accountPseudonym(
        _ credentials: ProviderCredentials, participantID: UUID, sourceID: UUID, on database: any Database
    ) async throws -> UUID {
        guard database.inTransaction else { throw AuditError.transactionRequired }
        let rows = try await ProviderSQL.sql(database).raw("""
            SELECT * FROM provider_connections WHERE participant_id = \(bind: participantID) AND source_id = \(bind: sourceID)
            ORDER BY created_at, id LIMIT 1025
            """).all()
        guard rows.count <= 1024 else { throw ProviderFailure.capacityExceeded }
        var matching: UUID?
        for row in rows {
            let connection = try ProviderConnection(row: row)
            let bytes = try vault.open(connection.accountEnvelope, context: connection.accountContext)
            guard let accountID = String(data: bytes, encoding: .utf8) else { throw ProviderFailure.unavailable }
            if accountID == credentials.accountID {
                guard matching == nil || matching == connection.accountPseudonym else { throw ProviderFailure.invalidConfiguration }
                matching = connection.accountPseudonym
            }
        }
        return matching ?? UUID()
    }
}
