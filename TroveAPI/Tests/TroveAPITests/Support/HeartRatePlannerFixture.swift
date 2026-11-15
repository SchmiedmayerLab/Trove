//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPIClient


enum HeartRatePlannerFixture {
    static let origin = Date(timeIntervalSince1970: 1_800_000_000)
    static let liveStart = origin.addingTimeInterval(100)

    static func date(_ offset: Double) -> Date { origin.addingTimeInterval(offset) }

    static func definition() throws -> Data { try HealthKitQueryDefinition(profile: .heartRate, kind: .live, start: liveStart).encoded() }

    static func plan(start: Double = -600, end: Double? = nil) -> Components.Schemas.ParticipantCollectionPlan {
        let requirement = Components.Schemas.CollectionPlanRequirement(
            profile: ParticipantCollectionSnapshot.heartRateProfile, sourceKind: .participantApp, start: date(start), end: end.map(date)
        )
        let window = Components.Schemas.ConsentCollectionWindow(
            consentId: UUID().uuidString, publicationId: UUID().uuidString, revision: 1, start: origin, requirements: [requirement]
        )
        return .init(
            enrollmentId: UUID().uuidString,
            studyId: UUID().uuidString,
            title: .init([.enUS: "Saved Study"]),
            stateVersion: 1,
            asOf: liveStart,
            windows: [window]
        )
    }

    static func adopt(
        _ plan: Components.Schemas.ParticipantCollectionPlan, at offset: Double, start: Double?
    ) -> Components.Schemas.ParticipantCollectionPlan {
        var next = plan
        let index = next.windows.count - 1
        next.windows[index].end = date(offset)
        for requirement in next.windows[index].requirements.indices {
            next.windows[index].requirements[requirement].end = date(offset)
        }
        let requirements: [Components.Schemas.CollectionPlanRequirement] = start.map {
            [.init(profile: ParticipantCollectionSnapshot.heartRateProfile, sourceKind: .participantApp, start: date($0))]
        } ?? []
        next.windows.append(.init(
            consentId: UUID().uuidString,
            publicationId: UUID().uuidString,
            revision: next.windows[index].revision + 1,
            start: date(offset),
            requirements: requirements
        ))
        next.stateVersion += 1
        next.asOf = date(offset)
        return next
    }

    static func retain(
        _ plans: [Components.Schemas.ParticipantCollectionPlan], in journal: EventDeliveryJournal
    ) async throws -> ParticipantCollectionState {
        let snapshot = try ParticipantCollectionSnapshot(plans: plans, enrollmentIDs: plans.compactMap { UUID(uuidString: $0.enrollmentId) })
        return try await journal.retainCollectionSnapshot(snapshot, replacing: journal.collectionState())
    }

    static func ranges(_ plan: HealthKitQueryPlan) -> [Range<Date>] {
        plan.queries.compactMap { query in query.definition.end.map { query.definition.start..<$0 } }.sorted { $0.lowerBound < $1.lowerBound }
    }
}
