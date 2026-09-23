//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SQLKit


struct DelegationPage: Sendable {
    let grants: [DelegationGrant]
    let nextBefore: UUID?
}


/// Application authorization metadata; never contains an OAuth credential.
struct DelegationGrant: Sendable {
    let id: UUID
    let studyID: UUID
    let grantor: AuditActor
    let clientID: String
    let preset: DelegationPreset
    let createdAt: Date
    let expiresAt: Date
    let revokedAt: Date?

    init(
        id: UUID,
        studyID: UUID,
        grantor: AuditActor,
        clientID: String,
        preset: DelegationPreset,
        createdAt: Date,
        expiresAt: Date,
        revokedAt: Date? = nil
    ) {
        self.id = id
        self.studyID = studyID
        self.grantor = grantor
        self.clientID = clientID
        self.preset = preset
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
    }

    init(row: any SQLRow) throws {
        id = try row.decode(column: "id", as: UUID.self)
        studyID = try row.decode(column: "study_id", as: UUID.self)
        grantor = try .init(
            issuer: row.decode(column: "grantor_issuer", as: String.self),
            subject: row.decode(column: "grantor_subject", as: String.self)
        )
        clientID = try row.decode(column: "client_id", as: String.self)
        preset = try row.decode(column: "preset", as: DelegationPreset.self)
        createdAt = try row.decode(column: "created_at", as: Date.self)
        expiresAt = try row.decode(column: "expires_at", as: Date.self)
        revokedAt = try row.decode(column: "revoked_at", as: Date?.self)
    }
}
