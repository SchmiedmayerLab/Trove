//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

#if canImport(HealthKit)

import Foundation
import GroveFHIRContract
import GroveHealthKit
import GroveHealthKitFHIR
import HealthKit
import TroveAPIClient


extension HealthKitAcquisition {
    /// A disabled stream may maintain its previously prepared records, but must not inspect or
    /// convert new samples. Keep the raw change count outside this selection to drain every page.
    func permittedChanges(
        _ delta: Delta,
        stream: HealthKitQueryDefinition.Stream,
        checkpoint: EventDeliveryJournal.Checkpoint,
        snapshot: ParticipantCollectionSnapshot
    ) async throws -> Delta {
        if snapshot.permitsAcquisition(stream: stream) {
            return delta
        }
        let known = try await journal.previouslyConvertedHealthKitRecords(delta.deletedIDs, from: checkpoint)
        return Delta(added: [], deletedIDs: known, nextAnchor: delta.nextAnchor)
    }

    func catchUp(
        localID: UUID,
        application: ApplicationDevice,
        host: HostDevice,
        query: @Sendable (HealthKitQueryDefinition, QueryAnchor) async throws -> Delta
    ) async throws -> Progress {
        try await checkSession()
        let setup = try await journal.sourceSetup(for: localID)
        guard let binding = setup.binding, !binding.isRevoked, let sourceID = UUID(uuidString: binding.source.id) else {
            throw EventDeliveryJournal.JournalError.sourceRevoked
        }
        let state = try await journal.collectionState()
        var plan = try await journal.healthKitQueryPlan(for: sourceID, state: state)
        var liveIDs = plan.liveQueries.map { $0.checkpoint.queryID }
        for _ in 0..<8 {
            try await checkSession()
            let nextLive = liveIDs.isEmpty ? nil : liveIDs.removeFirst()
            let selected = nextLive.flatMap { id in plan.queries.first { $0.checkpoint.queryID == id } } ?? plan.pendingQueries.first
            guard let selected else { break }
            _ = try await collect(
                localID: localID,
                application: application,
                host: host,
                selection: Selection(queryID: selected.checkpoint.queryID, state: state),
                query: query
            )
            plan = try await journal.healthKitQueryPlan(for: sourceID, state: state)
        }
        try await checkSession()
        return try await journal.finishHealthKitQuerySweep(plan, state: state) ? .caughtUp : .needsAnotherPass
    }
}


extension HealthKitAcquisition {
    static func query(
        _ healthKit: GroveHealthKit.HealthKit, definition: HealthKitQueryDefinition, anchor previous: QueryAnchor, maximumRecordingBytes: Int
    ) async throws -> Delta {
        var anchor = previous
        let options: HKQueryOptions = definition.profile.isInterval ? [] : [.strictStartDate]
        let predicate = HKQuery.predicateForSamples(withStart: definition.start, end: definition.end, options: options)
        switch definition.stream {
        case .heartRate:
            let changes = try await healthKit.query(.heartRate, timeRange: .ever, anchor: &anchor, limit: 64, predicate: predicate)
            return Delta(added: changes.added, deletedIDs: changes.deleted.map(\.uuid), nextAnchor: anchor)
        case .workout:
            let changes = try await healthKit.query(.workout, timeRange: .ever, anchor: &anchor, limit: 64, predicate: predicate)
            return Delta(added: changes.added, deletedIDs: changes.deleted.map(\.uuid), nextAnchor: anchor)
        case .workoutRoute:
            let changes = try await healthKit.query(.workoutRoute, timeRange: .ever, anchor: &anchor, limit: 1, predicate: predicate)
            return Delta(added: changes.added, deletedIDs: changes.deleted.map(\.uuid), nextAnchor: anchor) { route in
                try await HealthKitRecordingFile.workoutRoute(
                    route,
                    locations: HKWorkoutRouteQueryDescriptor(route).results(for: healthKit.healthStore),
                    relativePath: "recordings/\(route.uuid.uuidString.lowercased()).csv",
                    maximumByteCount: maximumRecordingBytes
                )
            }
        case .sleepStage:
            let changes = try await healthKit.query(.sleepAnalysis, timeRange: .ever, anchor: &anchor, limit: 64, predicate: predicate)
            return Delta(added: changes.added, deletedIDs: changes.deleted.map(\.uuid), nextAnchor: anchor)
        }
    }

    static func partition(_ delta: Delta, definition: HealthKitQueryDefinition) throws -> Delta {
        guard Set(delta.added.map(\.uuid)).count == delta.added.count,
              delta.added.allSatisfy({ $0.sampleType == sampleType(for: definition.stream) && $0.startDate.timeIntervalSince1970.isFinite
                  && $0.endDate.timeIntervalSince1970.isFinite && $0.endDate >= $0.startDate }) else {
            throw AcquisitionError.unsupportedDelta
        }
        return Delta(
            added: delta.added.filter { definition.contains($0.startDate, ending: definition.profile.isInterval ? $0.endDate : nil) },
            deletedIDs: delta.deletedIDs,
            nextAnchor: delta.nextAnchor,
            readRoute: delta.readRoute
        )
    }

    /// HealthKit read type for a supported collection measurement.
    public static func sampleType(for profile: CollectionObservationProfile) -> HKSampleType {
        sampleType(for: HealthKitQueryDefinition.Stream(profile))
    }

    /// HealthKit read type for each independently anchored stream.
    public static func sampleType(for stream: HealthKitQueryDefinition.Stream) -> HKSampleType {
        switch stream {
        case .heartRate: HKQuantityType(.heartRate)
        case .sleepStage: HKCategoryType(.sleepAnalysis)
        case .workout: HKSampleType.workoutType()
        case .workoutRoute: HKSeriesType.workoutRoute()
        }
    }
}

#endif
