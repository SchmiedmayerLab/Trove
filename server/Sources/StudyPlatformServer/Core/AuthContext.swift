//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
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

    let subject: String
    let email: String
    let roles: [String]
    let researcherRole: String
    let participantRole: String

    /// Parsed JWT group paths (e.g., "/Stanford Biodesign Digital Health/admin") as a membership map.
    let groupMemberships: [String: GroupRole]

    init(subject: String, email: String, roles: [String], groups: [String], researcherRole: String, participantRole: String) {
        self.subject = subject
        self.email = email
        self.roles = roles
        self.researcherRole = researcherRole
        self.participantRole = participantRole

        var memberships: [String: GroupRole] = [:]
        for path in groups {
            guard path.hasPrefix("/") else { continue }
            let parts = path.dropFirst().split(separator: "/", maxSplits: 1)
            guard parts.count == 2,
                  let role = GroupRole(rawValue: String(parts[1])) else {
                continue
            }
            memberships[String(parts[0])] = role
        }
        self.groupMemberships = memberships
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

    private static func requireCurrent() throws -> AuthContext {
        guard let context = current else {
            throw ServerError.missingToken
        }
        return context
    }
}
