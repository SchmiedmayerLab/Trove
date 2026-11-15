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
    var limits: EventSubmissionLimits.Configuration = .standard

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        metadata: ServerRequestMetadata,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let limit: Int
        switch operationID {
        case Operations.UploadParticipantRecordingTransfer.id:
            return try await next(request, recordingBody(request, body: body), metadata)
        case Operations.DeclareParticipantRecordingTransfer.id:
            limit = RecordingTransferDeclaration.maximumBytes
        case Operations.PostParticipantSourcesSourceIdEvents.id, Operations.SubmitParticipantEventBatch.id,
             Operations.SubmitParticipantRecordBundle.id:
            limit = limits.envelopeBytes
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

    /// Preserve streaming while checking transport metadata before any byte can reach storage.
    private func recordingBody(_ request: HTTPRequest, body: HTTPBody?) throws -> HTTPBody {
        _ = try AuthContext.checkIsParticipant()
        guard let body, request.headerFields[.contentEncoding] == nil,
              let rawLength = request.headerFields[.contentLength], !rawLength.isEmpty,
              rawLength.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int64(rawLength),
              (1...Int64(Int32.max)).contains(length) else {
            throw ServerError.badRequest("Recording upload requires Content-Length and no HTTP Content-Encoding")
        }
        return HTTPBody(body, length: .known(length), iterationBehavior: body.iterationBehavior)
    }
}
