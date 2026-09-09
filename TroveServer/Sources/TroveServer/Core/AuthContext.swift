//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


struct AuthContext: Sendable {
    enum GroupRole: String, Sendable, Comparable {
        case researcher
        case admin

        private var level: Int {
            switch self {
            case .researcher: 0
            case .admin: 1
            }
        }

        static func < (lhs: GroupRole, rhs: GroupRole) -> Bool {
            lhs.level < rhs.level
        }
    }

    @TaskLocal static var current: AuthContext?

    let issuer: String
    let subject: String
    let email: String
    let roles: [String]
    let researcherRole: String
    let participantRole: String
    /// Capture once at the trusted boundary and carry explicitly across database callbacks.
    let auditContext: AuditEvent.Context

    /// Parsed JWT group paths (e.g., "/Schmiedmayer Lab/admin") as a membership map.
    let groupMemberships: [String: GroupRole]
    /// Independent governed-data capability; administration alone does not imply it.
    let auditReaderGroups: Set<String>

    init(
        issuer: String,
        subject: String,
        email: String,
        roles: [String],
        groups: [String],
        researcherRole: String,
        participantRole: String,
        auditConfiguration: AuditConfiguration? = nil
    ) {
        self.issuer = issuer
        self.subject = subject
        self.email = email
        self.roles = roles
        self.researcherRole = researcherRole
        self.participantRole = participantRole
        self.auditContext = .init(actor: .init(issuer: issuer, subject: subject), applicationRevision: auditConfiguration?.applicationRevision)

        var memberships: [String: GroupRole] = [:]
        var auditReaders: Set<String> = []
        for path in groups {
            guard path.hasPrefix("/") else { continue }
            // Empty segments are invalid claims, not alternate spellings of a group.
            let parts = path.dropFirst().split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            let groupName = String(parts[0])
            if parts[1] == "audit-reader" {
                auditReaders.insert(groupName)
                continue
            }
            guard let role = GroupRole(rawValue: String(parts[1])) else { continue }
            memberships[groupName] = max(memberships[groupName] ?? role, role)
        }
        self.groupMemberships = memberships
        self.auditReaderGroups = auditReaders
    }

    @discardableResult
    static func checkIsResearcher() throws -> AuthContext {
        let context = try requireCurrent()
        guard context.roles.contains(context.researcherRole) else {
            throw ServerError.forbidden
        }
        return context
    }

    @discardableResult
    static func checkIsParticipant() throws -> AuthContext {
        let context = try requireCurrent()
        guard context.roles.contains(context.participantRole) else {
            throw ServerError.forbidden
        }
        return context
    }

    @discardableResult
    static func checkHasAccess(groupName: String, role: GroupRole) throws -> AuthContext {
        let context = try checkIsResearcher()
        guard let memberRole = context.groupMemberships[groupName], memberRole >= role else {
            throw ServerError.forbidden
        }
        return context
    }

    static func checkHasAuditAccess(groupName: String) throws {
        let context = try checkHasAccess(groupName: groupName, role: .admin)
        guard context.auditReaderGroups.contains(groupName) else { throw ServerError.forbidden }
    }

    private static func requireCurrent() throws -> AuthContext {
        guard let context = current else {
            throw ServerError.missingToken
        }
        return context
    }
}
