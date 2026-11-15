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
        // Evaluate each row once; a row's authority is the exact consent set per required output.
        let profiles = try SensorKitAcquisition.requiredProfiles(for: entry)
        let authorities = try batch.samples.map {
            try SensorKitSliceSelection.authority(
                for: $0.timeRange, profiles: profiles, sourceTypeIdentifier: entry.sourceToken, snapshot: snapshot
            )
        }
        let authority: (Int) -> SensorKitSliceSelection.Authority? = { authorities[$0] }
        let ranges: [Range<Int>]
        if usesSlices {
            ranges = try SensorKitSliceSelection.ranges(
                count: batch.samples.count, retained: covered, maximumSlices: limits.maximumRecordingFiles, authority: authority
            )
        } else {
            let rows = batch.samples.indices
            ranges = try SensorKitSliceSelection.sharedAuthority(rows, authority: authority) == nil ? [] : [rows]
        }
        var selected: [SensorKitAcquisition.Input] = []
        var slices: [SensorKitRecordingSlice] = []
        var retainedFileBytes = original.recordings.reduce(0) { $0 + $1.file.byteCount }
        for range in ranges {
            var input = try input(range: range, sliceIdentity: usesSlices)
            // Only a consent whose window selects every row may receive this slice.
            guard let permissions = try SensorKitSliceSelection.sharedAuthority(range, authority: authority) else {
                throw ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized
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
}
#endif
