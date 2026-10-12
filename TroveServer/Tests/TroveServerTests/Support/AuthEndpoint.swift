//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
@testable import TroveServer
import Vapor


enum AuthEndpointRole: Sendable {
    case researcher(minRole: AuthContext.GroupRole, requiresGroupAccess: Bool)
    /// Independent capability, not another rank in the researcher/admin hierarchy.
    case auditReader
    case participant
}


struct AuthEndpoint: Sendable {
    let method: HTTPMethod
    let path: String
    let body: Data?
    let contentType: HTTPMediaType?
    let role: AuthEndpointRole
    let successStatus: HTTPStatus
    var ifMatch: String?

    var isParticipant: Bool {
        if case .participant = role {
            return true
        }
        return false
    }

    var requiresGroupAccess: Bool {
        switch role {
        case .researcher(_, let required): required
        case .auditReader: true
        case .participant: false
        }
    }

    var minRole: AuthContext.GroupRole {
        switch role {
        case .researcher(let role, _): role
        case .auditReader: .admin
        case .participant: .researcher
        }
    }

    var requiresAuditReader: Bool {
        if case .auditReader = role {
            return true
        }
        return false
    }
}
