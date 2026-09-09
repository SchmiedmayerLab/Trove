//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import HTTPTypes
import OpenAPIRuntime
import TroveAPIServer


/// Bound ingestion envelopes before generated JSON decoding; authentication runs first.
struct ClinicalRequestBodyMiddleware: ServerMiddleware {
    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        metadata: ServerRequestMetadata,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let limit: Int
        switch operationID {
        case Operations.PostParticipantSourcesSourceIdEvents.id, Operations.SubmitParticipantEventBatch.id:
            limit = EventSubmissionLimits.maximumEnvelopeBytes
        case Operations.LookupParticipantEventReceipt.id, Operations.AttributeParticipantEvent.id: limit = 1024 * 1024
        default:
            return try await next(request, body, metadata)
        }
        _ = try AuthContext.checkIsParticipant()
        guard let body else { throw ServerError.invalidRequestBody }
        let bounded: HTTPBody
        do {
            bounded = HTTPBody(try await BoundedRequestBody.collect(body, upTo: limit))
        } catch BoundedRequestBody.ReadError.tooLarge {
            throw ServerError(status: .contentTooLarge, title: "Request Too Large", detail: "Clinical request exceeds its supported size")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            throw ServerError(status: .serviceUnavailable, title: "Upload Interrupted", detail: "Retry the unchanged request")
        }
        return try await next(request, bounded, metadata)
    }
}
