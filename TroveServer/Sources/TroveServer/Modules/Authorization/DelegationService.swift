//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import Grove


/// Grant management only; operation permissions remain in AuthorizationService.
/// Grove installs dependencies before serving requests; no request mutates service state.
final class DelegationService: Module, @unchecked Sendable {
    @Dependency(AuthorizationService.self) var authorizationService
    @Dependency(StudyRepository.self) var studyRepository
    let clientPolicy: KeycloakClientPolicy

    init(clientPolicy: KeycloakClientPolicy = .production) {
        self.clientPolicy = clientPolicy
    }

    func create(studyID: UUID, clientID: String, preset: DelegationPreset, expiresAt: Date) async throws -> DelegationGrant {
        let context = try AuthContext.checkIsResearcher()
        guard clientPolicy.permitsDelegation(to: clientID) else { throw ServerError.badRequest("Client does not support draft delegation") }
        let now = Date()
        guard expiresAt > now, expiresAt.timeIntervalSince(now) <= 86_400 else {
            throw ServerError.badRequest("Delegation expiry must be within the next 24 hours")
        }
        let access = try await authorizationService.prepareDraftAccess(operation: .edit)
        return try await studyRepository.database.transaction { transaction in
            let study = try await self.studyRepository.lockStudy(id: studyID, on: transaction)
            let audit = try await self.authorizationService.authorizeDraft(access, study: study, on: transaction)
            let grant = DelegationGrant(
                id: UUID(),
                studyID: studyID,
                grantor: context.auditContext.actor,
                clientID: clientID,
                preset: preset,
                createdAt: now,
                expiresAt: expiresAt
            )
            try await DelegationRepository.create(grant, on: transaction)
            try await AuditRepository.recordMutation(.init(
                context: audit,
                action: .delegationCreated,
                scope: .study(studyID: studyID, groupID: study.$group.id),
                target: .init(id: grant.id)
            ), on: transaction)
            return grant
        }
    }

    func list(studyID: UUID, before: UUID? = nil, limit: Int = 50) async throws -> DelegationPage {
        let context = try AuthContext.checkIsResearcher()
        let access = try await authorizationService.prepareDraftAccess(operation: .inspect)
        return try await studyRepository.database.transaction { transaction in
            let study = try await self.studyRepository.lockStudy(id: studyID, on: transaction)
            let audit = try await self.authorizationService.authorizeDraft(access, study: study, on: transaction)
            let group = try await study.$group.get(on: transaction)
            let owner = context.groupMemberships[group.name] == .admin ? nil : context.auditContext.actor
            let page = try await DelegationRepository.list(studyID: studyID, owner: owner, before: before, limit: limit, on: transaction)
            try await AuditRepository.recordDisclosureIntent(.init(
                context: audit,
                action: .delegationDisclosure,
                scope: .study(studyID: studyID, groupID: study.$group.id),
                target: .init(id: studyID)
            ), on: transaction)
            return page
        }
    }

    func revoke(studyID: UUID, delegationID: UUID) async throws -> DelegationGrant {
        let context = try AuthContext.checkIsResearcher()
        let access = try await authorizationService.prepareDraftAccess(operation: .edit)
        return try await studyRepository.database.transaction { transaction in
            let study = try await self.studyRepository.lockStudy(id: studyID, on: transaction)
            let audit = try await self.authorizationService.authorizeDraft(access, study: study, on: transaction)
            let group = try await study.$group.get(on: transaction)
            guard let grant = try await DelegationRepository.find(id: delegationID, studyID: studyID, on: transaction),
                  context.groupMemberships[group.name] == .admin
                    || (grant.grantor.issuer == context.issuer && grant.grantor.subject == context.subject) else {
                throw ServerError.forbidden
            }
            // Preserve the original revocation time and audit receipt on exact retries.
            guard grant.revokedAt == nil else {
                try await AuditRepository.recordDisclosureIntent(.init(
                    context: audit,
                    action: .delegationDisclosure,
                    scope: .study(studyID: studyID, groupID: study.$group.id),
                    target: .init(id: grant.id)
                ), on: transaction)
                return grant
            }
            let revoked = try await DelegationRepository.revoke(grant, at: Date(), on: transaction)
            try await AuditRepository.recordMutation(.init(
                context: audit,
                action: .delegationRevoked,
                scope: .study(studyID: studyID, groupID: study.$group.id),
                target: .init(id: grant.id)
            ), on: transaction)
            return revoked
        }
    }
}
