//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import GroveProviderFHIR
import TroveAPITypes


/// Current, exact consent purposes for one account connection. Windows are never widened across gaps.
struct ProviderDemand: Sendable {
    let consentID: UUID
    let profile: String
    let start: Date
    let end: Date
    var asOf: Date = .distantFuture

    init(consentID: UUID, profile: String, start: Date, end: Date, asOf: Date = .distantFuture) throws {
        let codec = TroveDateTranscoder()
        self.consentID = consentID
        self.profile = profile
        self.start = try codec.decode(codec.encode(start))
        self.end = try codec.decode(codec.encode(end))
        self.asOf = try codec.decode(codec.encode(asOf))
        guard self.start < self.end else { throw ProviderFailure.invalidConfiguration }
    }

    func contains(_ output: ClinicalGrantStore.Output) throws -> Bool {
        try output.profile == profile && output.measurementBounds.includes(windowStart: start, windowEnd: end, asOf: asOf)
    }
}


enum ProviderDemandStore {
    enum Purpose: Equatable {
        case acquisition
        case retainedCustody
        case closedWindowReconciliation

        func permits(_ enrollment: Enrollment, asOf: Date) -> Bool {
            guard enrollment.withdrawnAt == nil else { return false }
            return self != .acquisition || (enrollment.endsAt.map { $0 > asOf } ?? true)
        }
    }

    static let maximumDemands = 2048

    /// Caller holds participant → registration locks before any enrollment lock.
    // The authority kind remains explicit at both dispatch and commit-time checks.
    // swiftlint:disable:next function_parameter_count
    static func load(
        participantID: UUID, registration: ProviderRegistration, sourceToken: String, asOf: Date, purpose: Purpose, on database: any Database
    ) async throws -> [ProviderDemand] {
        guard database.inTransaction, registration.sourceTokens.contains(sourceToken),
              let capability = ProviderCapabilities.sources(for: registration.provider.converter).first(where: { $0.token == sourceToken }) else {
            throw ProviderFailure.fenced
        }
        let profiles = Set(capability.outputProfiles.compactMap { $0.value?.url.absoluteString })
        let rows = try await Enrollment.query(on: database)
            .filter(\.$participant.$id == participantID)
            .range(..<(maximumDemands + 1))
            .all()
        guard rows.count <= maximumDemands else { throw ProviderFailure.capacityExceeded }
        let ids = try rows.map { try $0.requireID() }.sorted { $0.uuidString < $1.uuidString }
        let repository = ConsentRepository(database: database)
        var result: [ProviderDemand] = []
        for id in ids {
            let enrollment = try await repository.lockEnrollment(id: id, on: database)
            // Enrollment end stops new acquisition; its bounded consent timeline still governs retained records.
            guard purpose.permits(enrollment, asOf: asOf) else { continue }
            let timeline = try await ConsentCollectionTimeline.load(enrollment: enrollment, on: database, asOf: asOf)
            for window in timeline {
                let acceptance = window.acceptance
                guard let publication = try await PublishedStudy.find(acceptance.publicationID, on: database),
                      publication.$study.id == enrollment.$study.id, publication.revision == acceptance.revision else {
                    throw ProviderFailure.unavailable
                }
                let requirements = try publication.collectionPolicy.resolvedRequirements(
                    studyID: enrollment.$study.id, revision: acceptance.revision, acceptedAt: acceptance.acceptedAt,
                    scope: acceptance.collectionScope, adoptionEnd: window.end
                )
                for requirement in requirements where requirement.sourceKind == .serverWorker
                    && requirement.providerRegistrationID == registration.id && requirement.sourceTypeIdentifier == sourceToken {
                    guard profiles.contains(requirement.profile) else { throw ProviderFailure.scopeLost }
                    if purpose == .closedWindowReconciliation {
                        guard let end = requirement.end, end <= asOf else { continue }
                    }
                    let end = min(requirement.end ?? asOf, asOf)
                    guard requirement.start < end else { continue }
                    result.append(try .init(
                        consentID: acceptance.consentID, profile: requirement.profile, start: requirement.start, end: end, asOf: asOf
                    ))
                    guard result.count <= maximumDemands else { throw ProviderFailure.capacityExceeded }
                }
            }
        }
        return result
    }

    static func targets(for outputs: [ClinicalGrantStore.Output], demands: [ProviderDemand]) throws -> [ClinicalEventTarget] {
        var selected: [UUID: Set<String>] = [:]
        for output in outputs {
            let matching = try demands.filter { try $0.contains(output) }
            guard !matching.isEmpty else { throw ProviderFailure.scopeLost }
            for demand in matching { selected[demand.consentID, default: []].insert(output.fullURL) }
        }
        return selected.keys.sorted { $0.uuidString < $1.uuidString }.map {
            .init(consentID: $0, outputFullURLs: selected[$0, default: []].sorted())
        }
    }

    /// Fetching one merged interval does not authorize fields outside its individual demand windows.
    static func windows(_ demands: [ProviderDemand]) -> [Range<Date>] {
        let sorted = demands.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var result: [Range<Date>] = []
        for demand in sorted {
            if let previous = result.last, demand.start <= previous.upperBound {
                result[result.count - 1] = previous.lowerBound..<max(previous.upperBound, demand.end)
            } else {
                result.append(demand.start..<demand.end)
            }
        }
        return result
    }
}
