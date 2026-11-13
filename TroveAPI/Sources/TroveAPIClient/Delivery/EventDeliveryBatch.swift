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

        init(_ attempt: EventDeliveryJournal.Attempt) throws {
            self.attempt = attempt
            record = try ExchangeRecord(validating: attempt.bytes)
            submission = try .init(commitment: attempt.commitment.receiptLookup, entryFullUrls: ExchangeRecordBytes(record).entryFullURLs)
        }
    }

    private(set) var members: [Member] = []
    private(set) var submission: Components.Schemas.RecordBundleSubmission?
    private var packer: ExchangeBundlePacker?
    private let packedAt: Date

    init(packedAt: Date) {
        self.packedAt = packedAt
    }

    /// A later version, another kind/source, or the transport bounds starts a new Bundle.
    mutating func append(_ member: Member) throws -> Bool {
        guard members.count < EventSubmissionLimits.maximumBatchEvents,
              members.first.map({
                  $0.attempt.commitment.sourceID == member.attempt.commitment.sourceID && $0.record.kind == member.record.kind
              }) ?? true else {
            return false
        }
        var candidate = packer ?? ExchangeBundlePacker(
            kind: member.record.kind,
            maximumRecords: EventSubmissionLimits.maximumBatchEvents,
            maximumBytes: EventSubmissionLimits.maximumBundleBytes
        )
        guard try candidate.insert(member.record) == .inserted else {
            return false
        }
        let graph = try candidate.bundle(packedAt: packedAt)
        guard graph.json.count <= EventSubmissionLimits.maximumBundleBytes else {
            return false
        }
        let submission = Components.Schemas.RecordBundleSubmission(
            bundleBase64: graph.json.base64EncodedString(), records: members.map(\.submission) + [member.submission]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard try encoder.encode(submission).count <= EventSubmissionLimits.maximumEnvelopeBytes else {
            return false
        }
        members.append(member)
        packer = candidate
        self.submission = submission
        return true
    }
}
