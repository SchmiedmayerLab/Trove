//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


enum DraftPermission: String, Codable, Sendable {
    case inspect
    case edit
    case validate
    case publish
}


enum DelegationPreset: String, Codable, Sendable {
    case inspectStudy
    case editStudyDraft

    var permissions: Set<DraftPermission> {
        switch self {
        case .inspectStudy: [.inspect]
        case .editStudyDraft: [.inspect, .edit, .validate]
        }
    }
}


struct GrantorAuthority: Sendable {
    let issuer: String
    let subject: String
    let enabled: Bool
    let roles: [String]
    let groups: [String]
}


/// An explicit injectable boundary, never a cache of previously granted authority.
struct GrantorAuthorityProvider: Sendable {
    static let unavailable = Self { _ in
        throw ServerError(status: .serviceUnavailable, title: "Authorization Unavailable", detail: "Try again later")
    }

    let fetch: @Sendable (AuditActor) async throws -> GrantorAuthority
}


/// Valid only for a short request-bound interval; queued work prepares new access.
struct DraftAccess: Sendable {
    let context: AuthContext
    let operation: DraftPermission
    let authority: GrantorAuthority?
    let preparedAt: Date
}
