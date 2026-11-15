// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

#if canImport(HealthKit)

import Foundation
import GroveHealthKit
import GroveHealthKitFHIR
import HealthKit
import TroveAPIClient


extension HealthKitAcquisition {
    static func queryFood(
        _ healthKit: GroveHealthKit.HealthKit, anchor: inout QueryAnchor, predicate: NSPredicate
    ) async throws -> Delta {
        let changes = try await healthKit.query(.food, timeRange: .ever, anchor: &anchor, limit: 1, predicate: predicate)
        return Delta(added: changes.added, deletedIDs: changes.deleted.map(\.uuid), nextAnchor: anchor)
    }

    /// Only accepted member streams receive durable conversion evidence; membership alone grants no authority.
    static func conversionSamples(
        _ samples: [HKSample], stream: HealthKitQueryDefinition.Stream, snapshot: ParticipantCollectionSnapshot
    ) throws -> [HKSample] {
        guard stream.profile == .food else {
            return samples
        }
        var result: [UUID: HKSample] = [:]
        for sample in samples {
            result[sample.uuid] = sample
            for (member, _) in try authorizedFoodMembers(sample, snapshot: snapshot) { result[member.uuid] = member }
        }
        guard result.count <= maximumPageOutputs else { throw EventDeliveryJournal.JournalError.capacityExceeded }
        return result.values.sorted { $0.uuid.uuidString < $1.uuid.uuidString }
    }

    private static func authorizedFoodMembers(
        _ sample: HKSample, snapshot: ParticipantCollectionSnapshot
    ) throws -> [(HKSample, HealthKitQueryDefinition.Stream)] {
        guard let correlation = sample as? HKCorrelation, correlation.correlationType == HKCorrelationType(.food) else {
            throw AcquisitionError.unsupportedDelta
        }
        guard correlation.objects.count < maximumPageOutputs else { throw EventDeliveryJournal.JournalError.capacityExceeded }
        return try correlation.objects.sorted { $0.uuid.uuidString < $1.uuid.uuidString }.compactMap { member in
            guard let stream = HealthKitQueryDefinition.Stream(rawValue: member.sampleType.identifier), stream.profile.quantitySource != nil else {
                return nil
            }
            return try consentIDs(for: member, stream: stream, snapshot: snapshot).isEmpty ? nil : (member, stream)
        }
    }

    static func prepareFood(
        _ delta: Delta,
        exporter: HealthKitFHIRExporter,
        snapshot: ParticipantCollectionSnapshot,
        timing: ConversionTiming,
        stream: HealthKitQueryDefinition.Stream
    ) async throws -> PreparedPage {
        var payloads: [EventDeliveryJournal.Payload] = []
        for sample in delta.added {
            let parentConsents = try Set(consentIDs(for: sample, stream: stream, snapshot: snapshot))
            guard !parentConsents.isEmpty else { continue }
            guard let instant = timing.records[sample.uuid] else { throw AcquisitionError.unsupportedDelta }
            let members = try authorizedFoodMembers(sample, snapshot: snapshot)
            var scopes: [UUID: (HealthKitQueryDefinition.Stream, Set<UUID>)] = [sample.uuid: (stream, parentConsents)]
            for (member, memberStream) in members {
                guard timing.records[member.uuid] != nil else { throw AcquisitionError.unsupportedDelta }
                scopes[member.uuid] = (memberStream, try Set(consentIDs(for: member, stream: memberStream, snapshot: snapshot)))
            }
            try await exporter.export(records: [.sample(sample)], at: instant, conversionInstants: timing.records) { result in
                guard let (outputStream, consents) = scopes[result.source.uuid] else {
                    return
                }
                guard case .record(let record) = result.outcome else { throw AcquisitionError.unsupportedDelta }
                if let prepared = try payload(for: record, stream: outputStream, snapshot: snapshot, nativeConsents: consents, recording: nil) {
                    payloads.append(prepared.payload)
                }
            }
        }
        // Deleting a grouping never asserts that the independent nutrient source samples were deleted.
        let deletions = try retractions(delta, timing: timing, stream: stream)
        try await exporter.retract(deletions, at: timing.batchInstant) { result in
            guard case .record(let record) = result.outcome else { throw AcquisitionError.unsupportedDelta }
            payloads.append(.init(bytes: record.json, targets: []))
        }
        guard payloads.count <= maximumPageOutputs else { throw EventDeliveryJournal.JournalError.capacityExceeded }
        return PreparedPage(payloads: payloads, recordingDeclarations: payloads.map { _ in [] })
    }
}

#endif
