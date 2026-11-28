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

    /// Why publication refuses a route the accepted candidate granted and that became unavailable after validation.
    var publicationRefusal: ValidationDiagnostic {
        let route = requirement.sourceKind == .serverWorker ? "provider registration" : "participant app"
        let nextAction = switch (requirement.requirement, requirement.sourceKind) {
        case (.required, .serverWorker):
            "Select an approved provider registration that qualifies this source, or mark the requirement optional, "
                + "and validate the draft again."
        case (.required, .participantApp):
            "Select a source the participant app supports, or mark the requirement optional, and validate the draft again."
        case (.optional, _):
            "Validate the draft again; the publication then records the optional requirement as unavailable."
        }
        return .trove(
            "route-unavailable",
            path: "collectionRequirements[\(index)]",
            message: "The \(requirement.profile) output through the \(route) route became unavailable after validation.",
            nextAction: nextAction
        )
    }
}


extension ProviderRegistrationService {
    /// Evaluates every requirement's route under the caller's transaction. A registration that is not approved, or that
    /// does not qualify the source and profile, makes its route unavailable; other failures propagate.
    ///
    /// Draft validation reads the registrations without row locks, so it never waits for or delays an operator's
    /// registration change. Publication locks each named registration (`lock: true`) so the registrations it
    /// accepts cannot change before it commits.
    func routes(
        for requirements: [CollectionRequirement], lock: Bool, on transaction: any Database
    ) async throws -> [CollectionRouteAvailability] {
        guard transaction.inTransaction else { throw AuditError.transactionRequired }
        var capabilities: [UUID: [Capability]] = [:]
        for id in Set(requirements.compactMap(\.providerRegistrationID)).sorted(by: { $0.uuidString < $1.uuidString }) {
            do {
                let registration = try await ProviderRegistrationStore.requireApproved(id, on: transaction, lock: lock).configuration
                capabilities[id] = self.capabilities(for: registration)
            } catch ProviderFailure.fenced {
                capabilities[id] = []
            } catch let failure as ProviderFailure where failure == .unavailable || failure == .invalidConfiguration {
                // A stored configuration that no longer decodes or validates is operator data that violates the
                // registration invariants, never an author's draft, so it stays a server error.
                transaction.logger.error("Stored provider registration is unreadable", metadata: [
                    "providerRegistrationID": .string(id.uuidString), "failure": .string(String(describing: failure))
                ])
                throw ServerError.providerRegistrationUnreadable
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
