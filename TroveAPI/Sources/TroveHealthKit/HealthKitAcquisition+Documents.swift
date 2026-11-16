// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

#if canImport(HealthKit)

import Foundation
import GroveHealthKit
import GroveHealthKitFHIR
import HealthKit
import TroveAPIClient


extension HealthKitAcquisition {
    static func documentType(for stream: HealthKitQueryDefinition.Stream) throws -> HKSampleType {
        #if os(watchOS)
        throw AcquisitionError.unsupportedDelta
        #else
        if stream.timeBasis == .cdaSourceDocumentPeriod {
            return HKDocumentType(.CDA)
        }
        return try clinicalType(for: stream).hkSampleType
        #endif
    }

    static func queryDocument(
        _ healthKit: GroveHealthKit.HealthKit,
        stream: HealthKitQueryDefinition.Stream,
        anchor previous: QueryAnchor,
        predicate: NSPredicate,
        maximumRecordingBytes: Int
    ) async throws -> Delta {
        #if os(watchOS)
        throw AcquisitionError.unsupportedDelta
        #else
        if stream.timeBasis == .cdaSourceDocumentPeriod {
            let page = try await healthKit.healthStore.queryCDADocumentEnvelopes(anchor: previous, limit: 1, predicate: predicate)
            return Delta(added: page.added, deletedIDs: page.deleted.map(\.uuid), nextAnchor: page.nextAnchor, readDocument: { envelope in
                guard let envelope = envelope as? HKCDADocumentSample else { throw AcquisitionError.unsupportedDelta }
                let document = try await healthKit.healthStore.requestCDADocument(envelope)
                return try await HealthKitRecordingFile.cdaDocument(
                    document, relativePath: "documents/\(document.uuid.uuidString.lowercased()).xml", maximumByteCount: maximumRecordingBytes
                )
            })
        }
        var anchor = previous
        let changes = try await healthKit.query(clinicalType(for: stream), timeRange: .ever, anchor: &anchor, limit: 1, predicate: predicate)
        return Delta(added: changes.added, deletedIDs: changes.deleted.map(\.uuid), nextAnchor: anchor, readDocument: { sample in
            guard let sample = sample as? HKClinicalRecord else { throw AcquisitionError.unsupportedDelta }
            return try await HealthKitRecordingFile.clinicalRecord(
                sample, relativePath: "documents/\(sample.uuid.uuidString.lowercased()).json", maximumByteCount: maximumRecordingBytes
            )
        })
        #endif
    }

    #if !os(watchOS)
    static func clinicalType(for stream: HealthKitQueryDefinition.Stream) throws -> SampleType<HKClinicalRecord> {
        guard stream.timeBasis == .clinicalRecordDownload, let identifier = stream.sourceTypeIdentifier,
              let type = SampleType<HKClinicalRecord>(HKClinicalTypeIdentifier(rawValue: identifier)) else {
            throw AcquisitionError.unsupportedDelta
        }
        return type
    }
    #endif
}

#endif
