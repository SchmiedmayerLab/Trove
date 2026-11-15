//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Fluent
import Foundation
import SQLKit
import TroveAPIServer


/// Loads one bounded custody record at a time under StudyDataQuery's locks. No result from
/// this store may leave the server before researcher authorization and audit commit.
struct StudyDataExportStore {
    static let maximumResponseBytes = StudyExportLimits.maximumPageBytes

    let database: any Database
    var limits: StudyExportLimits = .standard

    static func validateRetainedRecord(
        bytes: Data, digest: String, validator: String, recordings: [ClinicalRecordingAttachment] = []
    ) throws -> ValidatedExchangeEvent {
        guard !bytes.isEmpty, bytes.count <= FHIRValidationClient.maximumBytes, !validator.isEmpty,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == digest else {
            throw ServerError.internalServerError("Study data integrity check failed")
        }
        do {
            return try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: validator, recordings: recordings)
        } catch {
            throw ServerError.internalServerError("Study data projection is unavailable")
        }
    }

    func page(studyID: UUID, versions: StudyDataQuery.Versions, evidence: StudyDataFence) async throws -> Components.Schemas.StudyDataPage {
        guard database.inTransaction else { throw AuditError.transactionRequired }
        let grouped = Dictionary(grouping: evidence.page.outputs, by: \.eventID)
        var visited: Set<UUID> = []
        var records: [Components.Schemas.StudyDataRecord] = []
        // Reserve the bounded page envelope and record-array punctuation before retaining records.
        var encodedBytes = 1024
        let recordedAt = Date()
        for output in evidence.page.outputs where visited.insert(output.eventID).inserted {
            try Task.checkCancellation()
            guard let outputs = grouped[output.eventID] else { throw ServerError.unexpectedError }
            let record = try await record(studyID: studyID, versions: versions, outputs: outputs, evidence: evidence, recordedAt: recordedAt)
            let size = try JSONEncoder().encode(record).count
            guard size <= limits.pageBytes - encodedBytes else { throw StudyProjectionJSON.Failure.outputTooLarge }
            encodedBytes += size
            records.append(record)
        }
        let page = Components.Schemas.StudyDataPage(
            id: UUID().uuidString,
            studyId: studyID.uuidString,
            versions: versions == .current ? .current : .history,
            policy: .studyPointViewV1,
            records: records,
            nextBefore: evidence.page.nextBefore?.uuidString
        )
        guard try JSONEncoder().encode(page).count <= limits.pageBytes else { throw StudyProjectionJSON.Failure.outputTooLarge }
        return page
    }

    private func record(
        studyID: UUID, versions: StudyDataQuery.Versions, outputs: [StudyDataQuery.Output], evidence: StudyDataFence, recordedAt: Date
    ) async throws -> Components.Schemas.StudyDataRecord {
        guard let first = outputs.first, outputs.allSatisfy({ $0.enrollmentID == first.enrollmentID && $0.eventID == first.eventID }),
              let enrollment = evidence.enrollments.first(where: { $0.id == first.enrollmentID }) else { throw ServerError.unexpectedError }
        let nodes = Dictionary(uniqueKeysWithValues: outputs.map { ($0.nodeID, $0) })
        let identities = StudyDataIdentifiers(studyID: studyID)
        let grants = try evidence.grants.filter { nodes[$0.nodeID] != nil }.map { grant in
            guard let output = nodes[grant.nodeID], grant.enrollmentID == first.enrollmentID else { throw ServerError.unexpectedError }
            return try StudyPointExport.Grant(
                id: grant.id,
                outputFullURL: output.fullURL,
                enrollment: identities.enrollment(id: grant.enrollmentID, revision: grant.revision)
            )
        }
        let event = try await retainedEvent(id: first.eventID)
        var recordingURLs: [String: String] = [:]
        for attachment in event.recordings {
            let address = attachment.declaration.output.fullURL
            guard let grant = grants.first(where: { $0.outputFullURL == address }) else { continue }
            recordingURLs[address] = StudyRecordingLocation.path(studyID: studyID, grantID: grant.id, versions: versions)
        }
        let result = try StudyPointExport.build(
            event,
            grants: grants,
            context: identities.context(enrollmentID: enrollment.id, endsAt: enrollment.endsAt, recordedAt: recordedAt),
            recordingURLs: recordingURLs,
            maximumBytes: limits.bundleBytes
        )
        let lineage = Dictionary(uniqueKeysWithValues: result.sourceEntries.map { ($0.originalFullURL, $0) })
        let selected: [Components.Schemas.StudyDataOutput] = try outputs.map { output in
            guard let entry = lineage[output.fullURL] else { throw ServerError.unexpectedError }
            return .init(fullUrl: entry.derivedFullURL, isCurrent: output.isCurrent, sourceProfiles: entry.sourceProfiles)
        }
        return .init(id: result.id.uuidString, bundleBase64: result.json.base64EncodedString(), outputs: selected)
    }

    func retainedEvent(id: UUID) async throws -> ValidatedExchangeEvent {
        guard database.inTransaction else { throw AuditError.transactionRequired }
        guard let sql = database as? any SQLDatabase else { throw AuditError.unsupportedDatabase }
        let row = try await sql.raw("SELECT raw_bytes, raw_sha256, validator_identity FROM clinical_events WHERE id = \(bind: id)").first()
        guard let row else { throw ServerError.internalServerError("Study data is unavailable") }
        let bytes = try row.decode(column: "raw_bytes", as: Data.self)
        let digest = try row.decode(column: "raw_sha256", as: String.self)
        let validator = try row.decode(column: "validator_identity", as: String.self)
        let recordings = try await ClinicalRecordingStore.retained(eventID: id, on: database)
        return try Self.validateRetainedRecord(bytes: bytes, digest: digest, validator: validator, recordings: recordings)
    }
}
