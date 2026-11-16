//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

#if canImport(HealthKit)

import Crypto
import Foundation
import GroveFHIRContract
import GroveHealthKitFHIR
import HealthKit
import ModelsR4
import TroveAPIClient


extension HealthKitAcquisition {
    static func routePayload(
        for record: ExchangeRecord,
        recording: HealthKitRecordingFile,
        snapshot: ParticipantCollectionSnapshot,
        nativeConsents: Set<UUID>
    ) throws -> (payload: EventDeliveryJournal.Payload, declaration: Components.Schemas.RecordingTransferDeclaration)? {
        guard record.json.count <= EventSubmissionLimits.maximumEventBytes else { throw EventDeliveryJournal.JournalError.capacityExceeded }
        let graph = try ExchangeGraph(validating: record.json, kind: .active)
        let documents = (graph.bundle.entry ?? []).compactMap { entry -> (String, DocumentReference)? in
            guard case .documentReference(let document)? = entry.resource, let url = entry.fullUrl?.value?.url.absoluteString else {
                return nil
            }
            return (url, document)
        }
        guard documents.count == 1, let (url, document) = documents.first, record.outputFullURLs == [url],
              document.meta?.profile?.contains(Profile.healthkitRecordingDocument) == true,
              let profile = Profile.healthkitRecordingDocument.value?.url.absoluteString,
              let start = document.context?.period?.start?.value, let end = document.context?.period?.end?.value else {
            throw AcquisitionError.unsupportedDelta
        }
        let consents = try snapshot.consentIDs(
            profile: .workout, start: start.asNSDate(), end: end.asNSDate(), requiresWorkoutRoute: true
        )
        .filter { nativeConsents.contains($0) }
        guard !consents.isEmpty else {
            return nil
        }
        let compressed = try recording.file.zstandardCompressedIfSmaller(maximumByteCount: recording.file.byteCount)
        let stored = compressed ?? recording.file
        let sourceDigest = try digest(recording.file)
        let storedDigest = try compressed.map(digest) ?? sourceDigest
        let declaration = Components.Schemas.RecordingTransferDeclaration(
            attachmentPath: recording.relativePath,
            outputFullUrl: url,
            profile: profile,
            format: recording.format.rawValue,
            effectiveAt: try start.asNSDate(),
            effectiveEnd: try end.asNSDate(),
            content: .init(
                encoding: compressed == nil ? .identity : .zstd,
                storedByteCount: Int64(stored.byteCount),
                storedSHA256: storedDigest,
                sourceByteCount: Int64(recording.file.byteCount),
                sourceSHA256: sourceDigest
            ),
            targets: consents.map { .init(consentId: $0.uuidString.lowercased(), outputFullUrls: [url]) }
        )
        let payload = EventDeliveryJournal.Payload(
            bytes: record.json,
            targets: consents.map { .init(consentID: $0, outputFullURLs: [url]) },
            recordings: [.init(relativePath: recording.relativePath, byteCount: stored.byteCount) { try stored.readChunks($0) }]
        )
        return (payload, declaration)
    }

    private static func digest(_ file: RecordingFile) throws -> String {
        var hasher = SHA256()
        try file.readChunks { hasher.update(data: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

#endif
