//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPITypes


/// Explicit online reconciliation at synchronization, separate from ordinary cached collection authority.
public enum ParticipantNativeReconciliation {
    public enum RequestError: Error { case authenticationRequired, unavailable }

    /// Request or renew only unfinished closed scopes after a complete current enrollment refresh.
    public static func request(
        journal: EventDeliveryJournal,
        sourceID: UUID,
        state: ParticipantCollectionState,
        client: any APIProtocol,
        validateSession: @Sendable () async throws -> Void
    ) async throws -> [UUID] {
        try await checkSession(validateSession)
        let setup = try await journal.activeSource(sourceID)
        let credential = try await journal.installationCredential(for: setup.localID).base64EncodedString()
        guard let snapshot = state.snapshot else { throw ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized }
        var result: [UUID] = []
        for plan in snapshot.plans where plan.endsAt.map({ $0 <= .now }) == true {
            try await checkSession(validateSession)
            let instructions = try await reachingServer {
                let response = try await client.requestParticipantCollectionReconciliations(.init(
                    path: .init(enrollmentId: plan.enrollmentId),
                    headers: .init(troveSourceInstallationID: setup.localID.uuidString.lowercased(), troveSourceCredential: credential),
                    body: .json(.init(sourceId: sourceID.uuidString.lowercased()))
                ))
                switch response {
                case .ok(let value): return try value.body.json.instructions
                case .unauthorized: throw RequestError.authenticationRequired
                default: throw RequestError.unavailable
                }
            }
            try await checkSession(validateSession)
            try await journal.retainNativeReconciliations(instructions, for: sourceID, replacing: state)
            result += try instructions.map { value in
                guard let id = UUID(uuidString: value.id) else { throw ParticipantCollectionSnapshot.CollectionError.invalidPlan }
                return id
            }
        }
        try await checkSession(validateSession)
        return result
    }

    /// Retry lost acknowledgements without another HealthKit query or any dependency on upload receipts.
    public static func acknowledgeCompleted(
        journal: EventDeliveryJournal,
        sourceID: UUID,
        client: any APIProtocol,
        validateSession: @Sendable () async throws -> Void
    ) async throws {
        try await checkSession(validateSession)
        let setup = try await journal.activeSource(sourceID)
        let credential = try await journal.installationCredential(for: setup.localID).base64EncodedString()
        for completion in try await journal.completedNativeReconciliations(for: sourceID) {
            try await checkSession(validateSession)
            try await reachingServer {
                let response = try await client.completeParticipantCollectionReconciliation(.init(
                    path: .init(
                        enrollmentId: completion.enrollmentID.uuidString.lowercased(), reconciliationId: completion.id.uuidString.lowercased()
                    ),
                    headers: .init(troveSourceInstallationID: setup.localID.uuidString.lowercased(), troveSourceCredential: credential),
                    body: .json(.init(sourceId: sourceID.uuidString.lowercased()))
                ))
                switch response {
                case .noContent: break
                case .unauthorized: throw RequestError.authenticationRequired
                default: throw RequestError.unavailable
                }
            }
            try await checkSession(validateSession)
            try await journal.acknowledgeNativeReconciliation(completion.id, sourceID: sourceID)
        }
    }

    /// A transport failure or an undecodable reply leaves the retained state untouched for the next synchronization.
    private static func reachingServer<Value: Sendable>(_ operation: () async throws -> Value) async throws -> Value {
        do {
            return try await operation()
        } catch {
            try Task.checkCancellation()
            throw error as? RequestError ?? .unavailable
        }
    }

    private static func checkSession(_ validate: @Sendable () async throws -> Void) async throws {
        try Task.checkCancellation()
        do {
            try await validate()
        } catch {
            try Task.checkCancellation()
            throw RequestError.authenticationRequired
        }
        try Task.checkCancellation()
    }
}
