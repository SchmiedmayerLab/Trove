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
import GroveHealthKitFHIR
import HealthKit
import ModelsR4
import TroveAPIClient
import TroveAPITypes


extension HealthKitAcquisition {
    static func recordingPayload(
        for record: ExchangeRecord,
        recording: HealthKitRecordingFile,
        stream: HealthKitQueryDefinition.Stream,
        snapshot: ParticipantCollectionSnapshot,
        nativeConsents: Set<UUID>
    ) throws -> (payload: EventDeliveryJournal.Payload, declaration: Components.Schemas.RecordingTransferDeclaration)? {
        guard record.json.count <= EventSubmissionLimits.maximumEventBytes else { throw EventDeliveryJournal.JournalError.capacityExceeded }
        let graph = try ExchangeGraph(validating: record.json, kind: .active)
        let documents = recordingDocuments(graph)
        guard documents.count == 1, let (url, document) = documents.first, record.outputFullURLs == [url],
              document.meta?.profile?.contains(where: { $0.value?.url.absoluteString == stream.recordingProfile }) == true else {
            throw AcquisitionError.unsupportedDelta
        }
        let (start, end) = try recordingSelectionTime(graph: graph, document: document, stream: stream)
        let consents = try snapshot.consentIDs(
            profile: stream.profile,
            start: start,
            end: end,
            requiresWorkoutRoute: stream == .workoutRoute,
            sourceTypeIdentifier: stream.sourceTypeIdentifier,
            timeBasis: stream.timeBasis
        )
        .filter { nativeConsents.contains($0) }
        guard !consents.isEmpty else {
            return nil
        }
        let transfer = try PreparedRecordingTransfer(
            file: recording.file,
            attachmentPath: recording.relativePath,
            outputFullURL: url,
            profile: stream.recordingProfile,
            sourceTypeIdentifier: sampleType(for: stream).identifier,
            format: recording.format,
            effectiveAt: start,
            effectiveEnd: end,
            consentIDs: consents
        )
        let payload = EventDeliveryJournal.Payload(
            bytes: record.json,
            targets: consents.map { .init(consentID: $0, outputFullURLs: [url]) },
            recordings: [transfer.recording]
        )
        return (payload, transfer.declaration)
    }

    private static func recordingSelectionTime(
        graph: ExchangeGraph, document: DocumentReference, stream: HealthKitQueryDefinition.Stream
    ) throws -> (Date, Date) {
        if stream.timeBasis == .measurementTime {
            guard let start = document.context?.period?.start?.value, let end = document.context?.period?.end?.value else {
                throw AcquisitionError.unsupportedDelta
            }
            return try (start.asNSDate(), end.asNSDate())
        }
        guard document.context?.period == nil else { throw AcquisitionError.unsupportedDelta }
        let entities = (graph.bundle.entry ?? []).flatMap { entry -> [ProvenanceEntity] in
            guard case .provenance(let provenance)? = entry.resource else {
                return []
            }
            return provenance.entity ?? []
        }
        let time = try HealthKitDocumentSelectionTime(entities: entities, expectedBasis: stream.timeBasis)
        return (time.start, time.end)
    }

    private static func recordingDocuments(_ graph: ExchangeGraph) -> [(String, DocumentReference)] {
        (graph.bundle.entry ?? []).compactMap { entry in
            guard case .documentReference(let document)? = entry.resource, let url = entry.fullUrl?.value?.url.absoluteString else {
                return nil
            }
            return (url, document)
        }
    }
}

#endif
