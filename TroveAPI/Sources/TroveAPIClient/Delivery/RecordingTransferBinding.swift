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


/// Checks transfer facts against one exact output; the receiver still validates FHIR, decoded recording bytes and authority.
enum RecordingTransferBinding {
    private struct Entry: Decodable {
        let resource: Document
    }

    private struct Meta: Decodable { let profile: [String] }
    private struct Period: Decodable { let start: String; let end: String }
    private struct Context: Decodable { let period: Period? }
    private struct Coding: Decodable { let system: String; let code: String }
    private struct Attachment: Decodable {
        let url: String?
        let data: String?
        let size: Int64?
    }
    private struct Content: Decodable {
        let format: Coding
        let attachment: Attachment
    }
    private struct Document: Decodable {
        let resourceType: String
        let meta: Meta
        let content: [Content]
        let context: Context?
    }

    static func validate(
        _ commitment: RecordingTransferCommitment, file: DeliveryRecordingReference, bytes: Data, targetIntent: EventTargetIntent
    ) throws {
        let declaration = commitment.declaration
        guard file.relativePath == declaration.attachmentPath, Int64(file.byteCount) == declaration.content.storedByteCount,
              file.sha256 == declaration.content.storedSHA256 else { throw DeliveryJournalError.eventIdentityMismatch }
        let record = try ExchangeRecord(validating: bytes)
        guard record.outputFullURLs.contains(declaration.outputFullUrl),
              let bytes = try ExchangeRecordBytes(record).entryBytes(for: declaration.outputFullUrl) else {
            throw DeliveryJournalError.eventIdentityMismatch
        }
        let document = try JSONDecoder().decode(Entry.self, from: bytes).resource
        let dates = TroveDateTranscoder()
        guard document.resourceType == "DocumentReference", document.meta.profile.contains(declaration.profile),
              document.content.count == 1, let content = document.content.first,
              content.format.system == Canonicals.root + "/sensor/CodeSystem/grove-recording-format",
              content.format.code == declaration.format,
              content.attachment.url == file.relativePath, content.attachment.data == nil,
              content.attachment.size == declaration.content.sourceByteCount else { throw DeliveryJournalError.eventIdentityMismatch }
        if let period = document.context?.period {
            guard try dates.decode(period.start) == declaration.effectiveAt, try dates.decode(period.end) == declaration.effectiveEnd else {
                throw DeliveryJournalError.eventIdentityMismatch
            }
        }
        let selected = targetIntent.targets.compactMap { target -> EventTargetIntent.Target? in
            guard target.outputFullURLs.contains(declaration.outputFullUrl) else {
                return nil
            }
            return .init(consentID: target.consentID, outputFullURLs: [declaration.outputFullUrl])
        }
        guard try EventTargetIntent(targets: selected).serialized == commitment.intent.serialized else {
            throw DeliveryJournalError.eventIdentityMismatch
        }
    }
}
