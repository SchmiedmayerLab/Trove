//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPIClient


extension TroveAPIModule {
    func savedCollections(for session: KeycloakSessionSnapshot) async throws -> [ParticipantCollectionState.Collection] {
        try validateSession(session)
        let scope = EventDeliveryJournal.Scope(
            backend: Config.apiBaseURL.absoluteString, issuer: session.issuer.absoluteString, subject: session.subject
        )
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let collections = try await HealthDataStorage.collections(scope: scope, root: root)
        try validateSession(session)
        return collections
    }

    /// Refresh once at a foreground lifecycle boundary; bounded acquisition uses the retained result.
    func refreshCollectionPlans(journal: EventDeliveryJournal, for session: KeycloakSessionSnapshot) async throws {
        let client = try requireClient(for: session)
        _ = try await ParticipantCollectionRefresh.refresh(
            journal: journal,
            scope: .init(backend: Config.apiBaseURL.absoluteString, issuer: session.issuer.absoluteString, subject: session.subject),
            client: client,
            validateSession: { try await self.validateSession(session) }
        )
    }

    func stoppedEnrollments(for session: KeycloakSessionSnapshot) async throws -> Set<String> {
        try validateSession(session)
        let scope = EventDeliveryJournal.Scope(
            backend: Config.apiBaseURL.absoluteString, issuer: session.issuer.absoluteString, subject: session.subject
        )
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let stopped = try await HealthDataStorage.stoppedEnrollments(scope: scope, root: root)
        try validateSession(session)
        return Set(stopped.map { $0.uuidString.lowercased() })
    }

    /// Persist withdrawal intent before sending HTTP, including on a device that has not set up collection.
    /// HealthDataModel serializes the local writer; the revision check also invalidates stale external checkpoints.
    func stopCollection(enrollmentId: String, for session: KeycloakSessionSnapshot) async throws {
        try Task.checkCancellation()
        try validateSession(session)
        guard let id = UUID(uuidString: enrollmentId) else { throw ParticipantCollectionSnapshot.CollectionError.invalidPlan }
        let scope = EventDeliveryJournal.Scope(
            backend: Config.apiBaseURL.absoluteString, issuer: session.issuer.absoluteString, subject: session.subject
        )
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        try await HealthDataStorage.stopCollection(for: id, scope: scope, root: root)
        try validateSession(session)
    }
}
