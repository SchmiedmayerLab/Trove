//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import TroveAPITypes


/// One source-specific transport Bundle. Only its original records are persisted or retried.
struct EventDeliveryBatch {
    struct Member {
        let attempt: EventDeliveryJournal.Attempt
        let record: ExchangeRecord
        let submission: Components.Schemas.RecordBundleMember

        init(_ attempt: EventDeliveryJournal.Attempt, recordings: [Components.Schemas.RecordingAttachmentBinding] = []) throws {
            self.attempt = attempt
            record = try ExchangeRecord(validating: attempt.bytes)
            submission = try .init(
                commitment: attempt.commitment.receiptLookup,
                recordings: recordings.isEmpty ? nil : recordings,
                entryFullUrls: ExchangeRecordBytes(record).entryFullURLs
            )
        }
    }

    private(set) var members: [Member] = []
    private var packer: ExchangeBundlePacker?
    private let packedAt: Date
    private let limits: EventSubmissionLimits.Configuration

    init(packedAt: Date, limits: EventSubmissionLimits.Configuration = .standard) {
        self.packedAt = packedAt
        self.limits = limits
    }

    /// A later version, another kind/source, or the transport bounds starts a new Bundle.
    mutating func append(_ member: Member) throws -> Bool {
        guard member.attempt.bytes.count <= limits.recordBytes, members.count < limits.batchRecords,
              members.first.map({
                  $0.attempt.commitment.sourceID == member.attempt.commitment.sourceID && $0.record.kind == member.record.kind
              }) ?? true else {
            return false
        }
        var candidate = packer ?? ExchangeBundlePacker(
            kind: member.record.kind,
            maximumRecords: limits.batchRecords,
            maximumBytes: limits.bundleBytes
        )
        guard try candidate.insert(member.record) == .inserted else {
            return false
        }
        let bundleBytes = try candidate.bundleByteCount(packedAt: packedAt)
        guard bundleBytes <= limits.bundleBytes else {
            return false
        }
        // Base64 contains no JSON escapes under this encoder. Count its bytes without materializing the payload.
        let envelope = Components.Schemas.RecordBundleSubmission(
            bundleBase64: "", records: members.map(\.submission) + [member.submission]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let base64Bytes = ((bundleBytes + 2) / 3) * 4
        guard try encoder.encode(envelope).count + base64Bytes <= limits.envelopeBytes else {
            return false
        }
        members.append(member)
        packer = candidate
        return true
    }

    /// Materialize and validate once after membership is fixed, retaining the exact admission bounds.
    func submission() throws -> Components.Schemas.RecordBundleSubmission? {
        guard let packer else {
            return nil
        }
        let graph = try packer.bundle(packedAt: packedAt)
        let submission = Components.Schemas.RecordBundleSubmission(
            bundleBase64: graph.json.base64EncodedString(), records: members.map(\.submission)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard graph.json.count <= limits.bundleBytes, try encoder.encode(submission).count <= limits.envelopeBytes else {
            throw EventSubmissionCommitment.ValidationError.invalidEnvelope
        }
        return submission
    }
}
