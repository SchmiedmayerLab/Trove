//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPITypes


/// One source-specific wire envelope, not a second queue or persisted batch identity.
struct EventDeliveryBatch {
    struct Member {
        let attempt: EventDeliveryJournal.Attempt
        let submission: Components.Schemas.EventSubmission
        let encodedBytes: Int

        init(_ attempt: EventDeliveryJournal.Attempt) throws {
            self.attempt = attempt
            self.submission = .init(eventBase64: attempt.bytes.base64EncodedString(), targets: attempt.commitment.receiptLookup.targets)
            let encoder = JSONEncoder()
            // Matches Configuration.trove; no dates occur in this envelope.
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            self.encodedBytes = try encoder.encode(submission).count
        }
    }

    private(set) var members: [Member] = []
    private(set) var encodedBytes = "{\"events\":[]}".utf8.count
    private var base64Bytes = 0

    mutating func append(_ member: Member) -> Bool {
        let separatorBytes = members.isEmpty ? 0 : 1
        guard members.count < EventSubmissionLimits.maximumBatchEvents,
              members.first.map({ $0.attempt.commitment.sourceID == member.attempt.commitment.sourceID }) ?? true,
              member.submission.eventBase64.utf8.count <= EventSubmissionLimits.maximumBase64Bytes - base64Bytes,
              member.encodedBytes + separatorBytes <= EventSubmissionLimits.maximumEnvelopeBytes - encodedBytes else {
            return false
        }
        members.append(member)
        encodedBytes += member.encodedBytes + separatorBytes
        base64Bytes += member.submission.eventBase64.utf8.count
        return true
    }
}
