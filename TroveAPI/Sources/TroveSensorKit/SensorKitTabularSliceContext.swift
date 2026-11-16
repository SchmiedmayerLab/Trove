//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

#if os(iOS)
import Foundation
import GroveFHIRContract
import GroveSensorKit
import GroveSensorKitFHIR
import TroveAPIClient


struct TabularSliceContext<Row: SensorKitTabularSample> {
    let batch: GroveSensorKit.SensorKit.AnchoredBatch<Row>
    let entry: SensorKitCatalogEntry
    let title: String
    let snapshot: ParticipantCollectionSnapshot
    let limits: EventDeliveryJournal.Limits

    func prepare(
        covered: [SensorKitRecordingSlice], usesSlices: Bool, original: SensorKitAcquisition.Input, state: ParticipantCollectionState
    ) throws -> SensorKitAcquisition.SlicePreparation {
        let ranges: [Range<Int>]
        if usesSlices {
            ranges = try SensorKitSliceSelection.ranges(
                count: batch.samples.count, retained: covered, maximumSlices: limits.maximumRecordingFiles, authorized: authorized
            )
        } else {
            ranges = try batch.samples.indices.allSatisfy(authorized) && !batch.samples.isEmpty ? [batch.samples.indices] : []
        }
        var selected: [SensorKitAcquisition.Input] = []
        var slices: [SensorKitRecordingSlice] = []
        var retainedFileBytes = original.recordings.reduce(0) { $0 + $1.file.byteCount }
        for range in ranges {
            var input = try input(range: range, sliceIdentity: usesSlices)
            var permissions: [CollectionObservationProfile: Set<UUID>] = [:]
            for sample in batch.samples[range] {
                let row = try rowConsents(sample.timeRange)
                guard !row.isEmpty else { throw ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized }
                for (profile, consents) in row { permissions[profile, default: []].formUnion(consents) }
            }
            input.rowAuthorization = .init(consents: permissions)
            let bytes = input.recordings.reduce(0) { $0 + $1.file.byteCount }
            guard bytes <= limits.maximumPendingRecordingBytes - retainedFileBytes else { throw EventDeliveryJournal.JournalError.capacityExceeded }
            retainedFileBytes += bytes
            selected.append(input)
            if usesSlices {
                let slice = try SensorKitRecordingSlice(rows: range, sourceRecordID: input.sourceID.uuid, contentDigest: input.digest)
                if let previous = covered.first(where: { $0.rows == range }), previous != slice {
                    throw SensorKitAcquisition.AcquisitionError.retryMismatch
                }
                slices.append(slice)
            }
        }
        return .init(inputs: selected, state: state, slices: slices)
    }

    func input(range: Range<Int>, sliceIdentity: Bool) throws -> SensorKitAcquisition.Input {
        let file = try SensorKitTabularRecording.File(
            samples: batch.samples[range], deviceProductType: batch.info.device.productType, maximumByteCount: limits.maximumRecordingBytes
        )
        let identity = try sliceIdentity ? SensorKitSourceRecordID.derivedSlice(
            acquisitionBatch: batch.info.acquisitionBatch,
            sourceToken: entry.sourceToken,
            deviceProductType: batch.info.device.productType,
            rows: UInt64(range.lowerBound)..<UInt64(range.upperBound)
        ) : SensorKitSourceRecordID.derived(
            acquisitionBatch: batch.info.acquisitionBatch,
            sourceToken: entry.sourceToken,
            deviceProductType: batch.info.device.productType,
            recordOrdinal: 0
        )
        return try SensorKitAcquisition.tabularInput(file, entry: entry, sourceID: identity, title: title)
    }

    private func authorized(_ index: Int) throws -> Bool {
        try !rowConsents(batch.samples[index].timeRange).isEmpty
    }

    private func rowConsents(_ interval: Range<Date>) throws -> [CollectionObservationProfile: Set<UUID>] {
        var result: [CollectionObservationProfile: Set<UUID>] = [:]
        for profile in try SensorKitAcquisition.requiredProfiles(for: entry) {
            let consents = try snapshot.sensorKitRowConsentIDs(
                profile: profile,
                sourceTypeIdentifier: entry.sourceToken,
                start: interval.lowerBound,
                end: interval.isEmpty ? nil : interval.upperBound
            )
            guard !consents.isEmpty else {
                return [:]
            }
            result[profile] = Set(consents)
        }
        return result
    }
}
#endif
