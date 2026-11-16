//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SQLKit


/// Verifies stored transport bytes only; it grants no clinical custody or researcher access.
/// Expiry limits attachment acceptance, not the lifetime of this immutable receipt evidence.
struct RecordingTransferReceipt: Sendable, Equatable {
    let transferID: UUID
    let artifactID: UUID
    let declarationSHA256: String
    let storedByteCount: Int
    let storedSHA256: String
    let verifiedAt: Date
    let expiresAt: Date

    init(row: any SQLRow) throws {
        transferID = try row.decode(column: "transfer_id", as: UUID.self)
        artifactID = try row.decode(column: "artifact_id", as: UUID.self)
        declarationSHA256 = try row.decode(column: "declaration_sha256", as: String.self)
        storedByteCount = try row.decode(column: "stored_byte_count", as: Int.self)
        storedSHA256 = try row.decode(column: "stored_sha256", as: String.self)
        verifiedAt = try row.decode(column: "verified_at", as: Date.self)
        expiresAt = try row.decode(column: "expires_at", as: Date.self)
    }
}
