//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation


extension AuthorizationService {
    /// Remote identity checks happen before taking the study lock. Their observed decision
    /// cannot be atomic with the application database; application grant revocation can be.
    func prepareDraftAccess(operation: DraftPermission) async throws -> DraftAccess {
        let preparedAt = Date()
        let context = try AuthContext.requireCurrent()
        guard context.roles.contains(context.researcherRole),
              context.tokenExpiresAt.map({ $0 > Date() }) ?? true else { throw ServerError.forbidden }
        let authority: GrantorAuthority?
        switch context.clientAccess {
        case .interactive:
            guard context.delegationID == nil else { throw ServerError.forbidden }
            authority = operation == .publish ? try await grantorAuthority.fetch(context.auditContext.actor) : nil
        case .delegatedDraft:
            guard operation != .publish, context.delegationID != nil, context.executingClientID != nil else { throw ServerError.forbidden }
            authority = try await grantorAuthority.fetch(context.auditContext.actor)
        }
        try Task.checkCancellation()
        return DraftAccess(context: context, operation: operation, authority: authority, preparedAt: preparedAt)
    }

    /// Caller holds StudyRepository.lockStudy through its mutation/disclosure audit and commit.
    /// The header selected a grant; only this persisted, scope-bound check grants authority.
    func authorizeDraft(_ access: DraftAccess, study: Study, on transaction: any Database) async throws -> AuditEvent.Context {
        guard transaction.inTransaction else { throw AuditError.transactionRequired }
        let now = Date()
        let context = access.context
        guard now.timeIntervalSince(access.preparedAt) >= 0, now.timeIntervalSince(access.preparedAt) <= 30,
              context.tokenExpiresAt.map({ $0 > now }) ?? true,
              let group = try await Group.find(study.$group.id, on: transaction) else { throw ServerError.forbidden }
        var audit = context.auditContext
        switch context.clientAccess {
        case .interactive:
            let role: AuthContext.GroupRole = access.operation == .publish ? .admin : .researcher
            guard context.delegationID == nil, context.roles.contains(context.researcherRole),
                  let membership = context.groupMemberships[group.name], membership >= role else {
                throw ServerError.forbidden
            }
            if access.operation == .publish {
                try checkCurrentAuthority(access.authority, context: context, groupName: group.name, role: .admin)
            }
        case .delegatedDraft:
            guard let delegationID = context.delegationID, let clientID = context.executingClientID,
                  let grant = try await DelegationRepository.find(id: delegationID, studyID: study.requireId(), on: transaction),
                  grant.revokedAt == nil, grant.expiresAt > now, grant.createdAt <= now,
                  grant.clientID == clientID, grant.grantor.issuer == context.issuer, grant.grantor.subject == context.subject,
                  grant.preset.permissions.contains(access.operation) else { throw ServerError.forbidden }
            try checkCurrentAuthority(access.authority, context: context, groupName: group.name, role: .researcher)
            audit.initiator = grant.grantor
        }
        return audit
    }

    private func checkCurrentAuthority(
        _ authority: GrantorAuthority?, context: AuthContext, groupName: String, role: AuthContext.GroupRole
    ) throws {
        guard let authority, authority.enabled, authority.issuer == context.issuer, authority.subject == context.subject,
              authority.roles.contains(context.researcherRole) else { throw ServerError.forbidden }
        let currentMemberships = AuthContext(
            issuer: authority.issuer,
            subject: authority.subject,
            email: "",
            roles: authority.roles,
            groups: authority.groups,
            researcherRole: context.researcherRole,
            participantRole: context.participantRole
        ).groupMemberships
        guard let membership = currentMemberships[groupName], membership >= role else { throw ServerError.forbidden }
    }
}
