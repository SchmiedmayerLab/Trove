//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import OpenAPIRuntime
import TroveAPIServer


extension ClinicalEventService {
    /// Single and batched submissions share byte decoding, validation and atomic admission.
    func accept(submission: Components.Schemas.EventSubmission, sourceID: UUID) async throws -> ClinicalEventReceipt {
        _ = try AuthContext.checkIsParticipant()
        guard submission.eventBase64.utf8.count <= EventSubmissionLimits.maximumBase64Bytes else { throw FHIRValidationClient.tooLarge }
        guard let bytes = Data(base64Encoded: submission.eventBase64), !bytes.isEmpty,
              bytes.base64EncodedString() == submission.eventBase64 else {
            throw ServerError.badRequest("Provide canonical base64 of the original event")
        }
        guard bytes.count <= FHIRValidationClient.maximumBytes else { throw FHIRValidationClient.tooLarge }
        return try await accept(body: HTTPBody(bytes), sourceID: sourceID, targets: submission.targets.map { try $0.domainTarget })
    }

    func acceptBatch(
        _ submissions: [Components.Schemas.EventSubmission], sourceID: UUID
    ) async throws -> [Components.Schemas.EventBatchResult] {
        _ = try AuthContext.checkIsParticipant()
        guard (1...EventSubmissionLimits.maximumBatchEvents).contains(submissions.count) else {
            throw ServerError.badRequest("Submit between 1 and \(EventSubmissionLimits.maximumBatchEvents) events")
        }
        var total = 0
        for submission in submissions {
            guard submission.eventBase64.utf8.count <= EventSubmissionLimits.maximumBase64Bytes - total else { throw FHIRValidationClient.tooLarge }
            total += submission.eventBase64.utf8.count
        }
        try Task.checkCancellation()
        let source = try await SourceBindingService(database: database).find(id: sourceID)
        guard source.revokedAt == nil else { throw ServerError.conflict("Source binding is not active") }
        var results: [Components.Schemas.EventBatchResult] = []
        for submission in submissions {
            try Task.checkCancellation()
            do {
                let receipt = try await accept(submission: submission, sourceID: sourceID)
                results.append(.EventReceipt(receipt.apiRepresentation))
            } catch {
                // A lost/cancelled response can hide a committed prefix. Exact receipt recovery resolves it.
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                let status = (error as? ServerError)?.status.code ?? 500
                if status >= 500 {
                    database.logger.error("Clinical batch member failed", metadata: ["errorType": .string(String(reflecting: type(of: error)))])
                }
                results.append(.ProblemDetails(.init(
                    title: status >= 500 ? "Event Unavailable" : "Event Rejected",
                    status: status,
                    detail: status >= 500 ? "Retry the unchanged event" : "The event could not be admitted"
                )))
            }
        }
        try Task.checkCancellation()
        return results
    }
}
