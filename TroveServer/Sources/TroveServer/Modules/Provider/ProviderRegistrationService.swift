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
import GroveFHIRContract
import GroveProviderFHIR
import SQLKit


/// Participant-visible capabilities join operator approval with configured, implemented acquisition clients.
final class ProviderRegistrationService: Module, Sendable {
    struct Capability: Sendable {
        let sourceTypeIdentifier: String
        let profiles: [String]
        let effective: FHIRMeasurementDefinition.Effective
    }

    struct Available: Sendable {
        let id: UUID
        let provider: ConnectedProvider
        let displayName: String
        let controller: String
        let region: String
        let redirects: [ProviderRegistration.Redirect]
        let capabilities: [Capability]
    }

    let database: any Database
    let authorization: AuthorizationService
    let studies: StudyRepository
    let qualifiedTokens: [ConnectedProvider: Set<String>]
    let registrationIDs: Set<UUID>

    init(
        database: any Database, clients: [any ProviderAcquisitionClient], registrationIDs: Set<UUID>,
        authorization: AuthorizationService, studies: StudyRepository
    ) {
        self.database = database
        self.registrationIDs = registrationIDs
        self.authorization = authorization
        self.studies = studies
        var tokens: [ConnectedProvider: Set<String>] = [:]
        for client in clients { tokens[client.provider, default: []].formUnion(client.qualifiedSourceTokens) }
        self.qualifiedTokens = tokens
    }

    func registrations() async throws -> [Available] {
        let actor = try AuthContext.checkIsParticipant()
        guard let participant = try await Participant.query(on: database)
            .filter(\.$identityProviderIssuer == actor.issuer)
            .filter(\.$identityProviderId == actor.subject).first() else { throw ProviderFailure.fenced }
        let participantID = try participant.requireID()
        let rows = try await ProviderSQL.sql(database).raw("""
            SELECT id FROM provider_registrations WHERE approved = \(bind: true) ORDER BY id LIMIT 129
            """).all()
        guard rows.count <= 128 else { throw ProviderFailure.capacityExceeded }
        var available: [Available] = []
        for row in rows {
            let id = try row.decode(column: "id", as: UUID.self)
            let approved = try await ProviderRegistrationStore.requireApproved(id, on: database)
            let registration = approved.configuration
            let capabilities = capabilities(for: registration)
            guard !capabilities.isEmpty else { continue }
            let audit = AuditEvent(
                context: actor.auditContext, action: .providerRegistrationDisclosure,
                scope: .participantProvider(participantID: participantID, registrationID: id),
                target: .init(id: id, version: String(approved.generation))
            )
            available.append(try await AuditRepository.disclose(audit, on: database) { _ in
                Available(
                    id: id, provider: registration.provider, displayName: registration.displayName,
                    controller: registration.controller, region: registration.region,
                    redirects: registration.redirects, capabilities: capabilities
                )
            })
        }
        return available
    }

    /// Authoring capabilities require edit authority but do not change the draft revision or disclose connected accounts.
    func registrations(studyID: UUID) async throws -> [Available] {
        let access = try await authorization.prepareDraftAccess(operation: .edit)
        return try await database.transaction { transaction in
            let study = try await self.studies.lockStudy(id: studyID, on: transaction)
            let context = try await self.authorization.authorizeDraft(access, study: study, on: transaction)
            let rows = try await ProviderSQL.sql(transaction).raw("""
                SELECT id FROM provider_registrations WHERE approved = \(bind: true) ORDER BY id LIMIT 129
                """).all()
            guard rows.count <= 128 else { throw ProviderFailure.capacityExceeded }
            var available: [Available] = []
            for row in rows {
                let id = try row.decode(column: "id", as: UUID.self)
                let registration = try await ProviderRegistrationStore.requireApproved(id, on: transaction).configuration
                let capabilities = self.capabilities(for: registration)
                guard !capabilities.isEmpty else { continue }
                available.append(Available(
                    id: id, provider: registration.provider, displayName: registration.displayName,
                    controller: registration.controller, region: registration.region,
                    redirects: registration.redirects, capabilities: capabilities
                ))
            }
            try await AuditRepository.recordDisclosureIntent(.init(
                context: context, action: .studyDraftDisclosure,
                scope: .study(studyID: studyID, groupID: study.$group.id),
                target: .init(id: studyID, version: study.draftRevision.uuidString)
            ), on: transaction)
            return available
        }
    }

    /// Publication checks the actual receiver/acquisition intersection again under the acceptance transaction.
    func validate(requirements: [CollectionRequirement], on transaction: any Database) async throws {
        guard transaction.inTransaction else { throw AuditError.transactionRequired }
        let required = requirements.filter { $0.sourceKind == .serverWorker }
        let identifiers = Set(required.compactMap(\.providerRegistrationID)).sorted { $0.uuidString < $1.uuidString }
        guard required.allSatisfy({ $0.providerRegistrationID != nil && $0.sourceTypeIdentifier != nil }) else {
            throw ProviderFailure.scopeLost
        }
        for id in identifiers {
            let registration = try await ProviderRegistrationStore.requireApproved(id, on: transaction, lock: true).configuration
            let capabilities = capabilities(for: registration)
            for requirement in required where requirement.providerRegistrationID == id {
                guard capabilities.contains(where: {
                    $0.sourceTypeIdentifier == requirement.sourceTypeIdentifier && $0.profiles.contains(requirement.profile)
                }) else { throw ProviderFailure.scopeLost }
            }
        }
    }

    func capabilities(for registration: ProviderRegistration) -> [Capability] {
        guard registrationIDs.contains(registration.id) else { return [] }
        let qualified = qualifiedTokens[registration.provider, default: []].intersection(registration.sourceTokens)
        return ProviderCapabilities.sources(for: registration.provider.converter).compactMap { source in
            guard qualified.contains(source.token), source.conversionSupport == .structured, let effective = source.effective else { return nil }
            return Capability(
                sourceTypeIdentifier: source.token,
                profiles: source.outputProfiles.compactMap { $0.value?.url.absoluteString }.sorted(), effective: effective
            )
        }.sorted { $0.sourceTypeIdentifier < $1.sourceTypeIdentifier }
    }
}
