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
        reviewDocuments: Bool = false,
        query: @Sendable (HealthKitQueryDefinition, QueryAnchor) async throws -> Delta
    ) async throws -> Progress {
        try await checkSession()
        let setup = try await journal.sourceSetup(for: localID)
        guard let binding = setup.binding, !binding.isRevoked, let sourceID = UUID(uuidString: binding.source.id) else {
            throw EventDeliveryJournal.JournalError.sourceRevoked
        }
        let state = try await journal.collectionState()
        if reviewDocuments {
            guard let active = try state.snapshot?.active(at: .now), active.permitsDocumentReview else {
                throw ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized
            }
        }
        var plan = try await journal.healthKitQueryPlan(for: sourceID, state: state)
        var liveIDs = plan.liveQueries.filter { ($0.definition.stream.timeBasis == .cdaSourceDocumentPeriod) == reviewDocuments }
            .map { $0.checkpoint.queryID }
        for _ in 0..<8 {
            try await checkSession()
            let nextLive = liveIDs.isEmpty ? nil : liveIDs.removeFirst()
            let selected = nextLive.flatMap { id in plan.queries.first { $0.checkpoint.queryID == id } }
                ?? plan.pendingQueries.first { ($0.definition.stream.timeBasis == .cdaSourceDocumentPeriod) == reviewDocuments }
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
        return try await journal.finishHealthKitQuerySweep(plan, state: state, reviewDocuments: reviewDocuments) ? .caughtUp : .needsAnotherPass
    }
}


extension HealthKitAcquisition {
    static func query(
        _ healthKit: GroveHealthKit.HealthKit,
        definition: HealthKitQueryDefinition,
        anchor previous: QueryAnchor,
        maximumRecordingBytes: Int,
        reviewDocuments: Bool = false
    ) async throws -> Delta {
        var anchor = previous
        let options: HKQueryOptions = definition.usesOverlapPredicate ? [] : [.strictStartDate]
        let predicate = HKQuery.predicateForSamples(withStart: definition.start, end: definition.end, options: options)
        if definition.stream.timeBasis != .measurementTime {
            guard reviewDocuments || definition.stream.timeBasis != .cdaSourceDocumentPeriod else {
                throw AcquisitionError.documentReviewRequired
            }
            return try await queryDocument(
                healthKit, stream: definition.stream, anchor: anchor, predicate: predicate, maximumRecordingBytes: maximumRecordingBytes
            )
        }
        switch definition.stream {
        case .workout:
            let changes = try await healthKit.query(.workout, timeRange: .ever, anchor: &anchor, limit: 64, predicate: predicate)
            return Delta(added: changes.added, deletedIDs: changes.deleted.map(\.uuid), nextAnchor: anchor)
        case .workoutRoute:
            let changes = try await healthKit.query(.workoutRoute, timeRange: .ever, anchor: &anchor, limit: 1, predicate: predicate)
            return Delta(added: changes.added, deletedIDs: changes.deleted.map(\.uuid), nextAnchor: anchor, readRoute: { route in
                try await HealthKitRecordingFile.workoutRoute(
                    route,
                    locations: HKWorkoutRouteQueryDescriptor(route).results(for: healthKit.healthStore),
                    relativePath: "recordings/\(route.uuid.uuidString.lowercased()).csv",
                    maximumByteCount: maximumRecordingBytes
                )
            })
        case .sleepStage:
            let changes = try await healthKit.query(.sleepAnalysis, timeRange: .ever, anchor: &anchor, limit: 64, predicate: predicate)
            return Delta(added: changes.added, deletedIDs: changes.deleted.map(\.uuid), nextAnchor: anchor)
        default:
            if definition.stream.profile == .healthKitRecording {
                return try await queryHeartbeats(healthKit, anchor: &anchor, predicate: predicate, maximumRecordingBytes: maximumRecordingBytes)
            }
            return try await queryObservation(healthKit, stream: definition.stream, anchor: &anchor, predicate: predicate)
        }
    }

    static func partition(_ delta: Delta, definition: HealthKitQueryDefinition) throws -> Delta {
        let expectedType = try sampleType(for: definition.stream)
        guard Set(delta.added.map(\.uuid)).count == delta.added.count,
              delta.added.allSatisfy({ $0.sampleType == expectedType && $0.startDate.timeIntervalSince1970.isFinite
                  && $0.endDate.timeIntervalSince1970.isFinite && $0.endDate >= $0.startDate }) else {
            throw AcquisitionError.unsupportedDelta
        }
        return Delta(
            added: delta.added.filter { definition.contains($0.startDate, ending: definition.usesOverlapPredicate ? $0.endDate : nil) },
            deletedIDs: delta.deletedIDs,
            nextAnchor: delta.nextAnchor,
            readHeartbeatSeries: delta.readHeartbeatSeries,
            readDocument: delta.readDocument,
            readRoute: delta.readRoute
        )
    }

    /// HealthKit read type for a supported collection measurement.
    public static func sampleType(for profile: CollectionObservationProfile) throws -> HKSampleType {
        try sampleType(for: HealthKitQueryDefinition.Stream(profile))
    }

    /// HealthKit read type for each independently anchored stream.
    public static func sampleType(for stream: HealthKitQueryDefinition.Stream) throws -> HKSampleType {
        if stream.timeBasis != .measurementTime {
            return try documentType(for: stream)
        }
        return switch stream {
        case .sleepStage: HKCategoryType(.sleepAnalysis)
        case .workout: HKSampleType.workoutType()
        case .workoutRoute: HKSeriesType.workoutRoute()
        default: try observationType(for: stream)
        }
    }

    private static func observationType(for stream: HealthKitQueryDefinition.Stream) throws -> HKSampleType {
        switch stream.profile {
        case .food: SampleType.food.hkSampleType
        case .bloodPressure: SampleType.bloodPressure.hkSampleType
        case .stateOfMind: SampleType.stateOfMind.hkSampleType
        case .gad7: SampleType.gad7.hkSampleType
        case .phq9: SampleType.phq9.hkSampleType
        case .audiogram: SampleType.audiogram.hkSampleType
        case .healthKitRecording: SampleType.heartbeatSeries.hkSampleType
        default:
            if stream.profile.categorySource != nil {
                try categoryType(for: stream).hkSampleType
            } else {
                try quantityType(for: stream).hkSampleType
            }
        }
    }

    private static func queryObservation(
        _ healthKit: GroveHealthKit.HealthKit, stream: HealthKitQueryDefinition.Stream, anchor: inout QueryAnchor, predicate: NSPredicate
    ) async throws -> Delta {
        switch stream.profile {
        case .food: try await queryFood(healthKit, anchor: &anchor, predicate: predicate)
        case .bloodPressure: try await querySamples(.bloodPressure, healthKit: healthKit, anchor: &anchor, predicate: predicate)
        case .stateOfMind: try await querySamples(.stateOfMind, healthKit: healthKit, anchor: &anchor, predicate: predicate)
        case .gad7: try await querySamples(.gad7, healthKit: healthKit, anchor: &anchor, predicate: predicate)
        case .phq9: try await querySamples(.phq9, healthKit: healthKit, anchor: &anchor, predicate: predicate)
        case .audiogram: try await querySamples(.audiogram, healthKit: healthKit, anchor: &anchor, predicate: predicate)
        default:
            if stream.profile.categorySource != nil {
                try await querySamples(categoryType(for: stream), healthKit: healthKit, anchor: &anchor, predicate: predicate)
            } else {
                try await querySamples(quantityType(for: stream), healthKit: healthKit, anchor: &anchor, predicate: predicate)
            }
        }
    }

    private static func querySamples<Sample>(
        _ type: SampleType<Sample>, healthKit: GroveHealthKit.HealthKit, anchor: inout QueryAnchor, predicate: NSPredicate
    ) async throws -> Delta {
        let changes = try await healthKit.query(type, timeRange: .ever, anchor: &anchor, limit: 64, predicate: predicate)
        return Delta(added: changes.added, deletedIDs: changes.deleted.map(\.uuid), nextAnchor: anchor)
    }

    static func categoryType(for stream: HealthKitQueryDefinition.Stream) throws -> SampleType<HKCategorySample> {
        guard let source = stream.profile.nativeSources.first(where: { $0.sourceTypeIdentifier == stream.sourceTypeIdentifier }),
              HealthKitSourceType(rawValue: source.sourceTypeIdentifier) != nil,
              let type = SampleType<HKCategorySample>(HKCategoryTypeIdentifier(rawValue: source.sourceTypeIdentifier)) else {
            throw AcquisitionError.unsupportedDelta
        }
        return type
    }

    /// Reuse Grove's typed SDK lookup; guide membership alone never manufactures an unavailable type.
    static func quantityType(for stream: HealthKitQueryDefinition.Stream) throws -> SampleType<HKQuantitySample> {
        guard let source = stream.profile.nativeSources.first(where: { $0.sourceTypeIdentifier == stream.sourceTypeIdentifier }),
              HealthKitSourceType(rawValue: source.sourceTypeIdentifier) != nil,
              let type = SampleType<HKQuantitySample>(HKQuantityTypeIdentifier(rawValue: source.sourceTypeIdentifier)) else {
            throw AcquisitionError.unsupportedDelta
        }
        return type
    }
}

#endif
