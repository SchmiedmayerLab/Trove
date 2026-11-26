//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation


/// Whether this deployment implements the route of one collection requirement.
struct CollectionRouteAvailability: Sendable {
    let index: Int
    let requirement: CollectionRequirement
    let available: Bool

    /// The publication blocker of a required route that is unavailable, or the advisory of an optional one.
    var diagnostic: ValidationDiagnostic? {
        guard !available else {
            return nil
        }
        let path = "collectionRequirements[\(index)]"
        let route = requirement.sourceKind == .serverWorker ? "provider registration" : "participant app"
        switch requirement.requirement {
        case .required:
            return .trove(
                "route-unavailable",
                path: path,
                message: "This deployment cannot collect the required \(requirement.profile) output through the \(route) route.",
                nextAction: requirement.sourceKind == .serverWorker
                    ? "Select an approved provider registration that qualifies this source, or mark the requirement optional."
                    : "Select a source the participant app supports, or mark the requirement optional."
            )
        case .optional:
            return .trove(
                "route-optional-unavailable",
                path: path,
                message: "The optional \(requirement.profile) output through the \(route) route is unavailable; "
                    + "the publication records it as unavailable and grants no collection for it.",
                severity: .warning
            )
        }
    }
}


extension ProviderRegistrationService {
    /// Evaluates every requirement's route under the caller's transaction, locking each named registration as
    /// publication does. A registration that is not approved, or that does not qualify the source and profile,
    /// makes its route unavailable; other failures propagate.
    func routes(for requirements: [CollectionRequirement], on transaction: any Database) async throws -> [CollectionRouteAvailability] {
        guard transaction.inTransaction else { throw AuditError.transactionRequired }
        var capabilities: [UUID: [Capability]] = [:]
        for id in Set(requirements.compactMap(\.providerRegistrationID)).sorted(by: { $0.uuidString < $1.uuidString }) {
            do {
                let registration = try await ProviderRegistrationStore.requireApproved(id, on: transaction, lock: true).configuration
                capabilities[id] = self.capabilities(for: registration)
            } catch ProviderFailure.fenced {
                capabilities[id] = []
            }
        }
        return requirements.enumerated().map { index, requirement in
            let available: Bool
            switch requirement.sourceKind {
            case .participantApp:
                available = requirement.hasSupportedNativeSource
            case .serverWorker:
                available = requirement.providerRegistrationID.flatMap { capabilities[$0] }?.contains {
                    $0.sourceTypeIdentifier == requirement.sourceTypeIdentifier && $0.profiles.contains(requirement.profile)
                } ?? false
            }
            return CollectionRouteAvailability(index: index, requirement: requirement, available: available)
        }
    }
}
