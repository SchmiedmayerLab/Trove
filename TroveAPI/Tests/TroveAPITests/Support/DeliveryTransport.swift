//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
import TroveAPIClient


/// Synthetic HTTP peer for the real generated client; not a replacement for receiver/FHIR acceptance.
actor DeliveryTransport: ClientTransport {
    enum Behavior: Sendable {
        case accept
        case loseFirstResponse
        case reject(Int)
        case rejectFirst
        case mismatch
        case mismatchFirst
        case rateLimit
        case unavailable(retryAfter: String)
        case malformedReceipt
        case partialLoss(Int)
        case responseCountDelta(Int)
        case reverseResults
        case problemStatus(Int)
    }

    private var behavior: Behavior = .accept
    private var receipts: [String: Components.Schemas.EventReceipt] = [:]
    private var replyAction: (@Sendable () async -> Void)?
    private(set) var paths: [String] = []
    private(set) var submittedBytes: [Data] = []
    private(set) var submittedBatches: [Components.Schemas.EventBatchSubmission] = []
    private(set) var batchBodyBytes: [Int] = []
    private(set) var batchSourceIDs: [UUID] = []

    func configure(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func onReply(_ action: @escaping @Sendable () async -> Void) {
        replyAction = action
    }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        let body = try #require(body)
        let bytes = try await Data(collecting: body, upTo: 6 * 1024 * 1024)
        let path = try #require(request.path)
        paths.append(path)
        #expect(baseURL.absoluteString == DeliveryFixture.scope.backend)
        let response: (HTTPResponse, HTTPBody?)
        if path.hasSuffix("/event-receipts/lookup") {
            let lookup = try JSONDecoder().decode(Components.Schemas.EventReceiptLookup.self, from: bytes)
            if let receipt = receipts[lookup.producerEventIdentifier.value] {
                #expect(lookup.payloadSHA256 == receipt.payloadSHA256)
                response = try encoded(receipt)
            } else {
                response = rejected(404)
            }
        } else {
            #expect(path.hasSuffix("/events/batch"))
            let components = path.split(separator: "/")
            let sourceIndex = try #require(components.firstIndex(of: "sources"))
            let sourceID = try #require(UUID(uuidString: String(components[sourceIndex + 1])))
            response = try submit(bytes, sourceID: sourceID)
        }
        let action = replyAction
        replyAction = nil
        await action?()
        return response
    }

    private func submit(_ bytes: Data, sourceID: UUID) throws -> (HTTPResponse, HTTPBody?) {
        let batch = try JSONDecoder().decode(Components.Schemas.EventBatchSubmission.self, from: bytes)
        let priorCount = submittedBytes.count
        submittedBatches.append(batch)
        batchBodyBytes.append(bytes.count)
        batchSourceIDs.append(sourceID)
        for request in batch.events { submittedBytes.append(try #require(Data(base64Encoded: request.eventBase64))) }
        if case .reject(let code) = behavior {
            return rejected(code)
        }
        if case .malformedReceipt = behavior {
            return (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody("{}"))
        }
        if case .rateLimit = behavior {
            return (HTTPResponse(status: .tooManyRequests, headerFields: [.retryAfter: "120"]), nil)
        }
        if case .unavailable(let deadline) = behavior {
            var response = rejected(503)
            response.0.headerFields[.retryAfter] = deadline
            return response
        }
        var results: [Components.Schemas.EventBatchResult] = []
        for (index, request) in batch.events.enumerated() {
            if case .rejectFirst = behavior, priorCount + index == 0 {
                results.append(.ProblemDetails(.init(title: "Synthetic rejection", status: 422)))
            } else {
                results.append(.EventReceipt(try admit(request, sourceID: sourceID)))
            }
            if case .partialLoss(let count) = behavior, submittedBatches.count == 1, index + 1 == count {
                throw URLError(.networkConnectionLost)
            }
        }
        if case .loseFirstResponse = behavior, submittedBatches.count == 1 { throw URLError(.networkConnectionLost) }
        return try encoded(altered(results))
    }

    private func altered(_ original: [Components.Schemas.EventBatchResult]) throws -> [Components.Schemas.EventBatchResult] {
        var results = original
        if case .mismatchFirst = behavior, case .EventReceipt(var receipt) = results[0] {
            receipt.payloadSHA256 = String(repeating: "0", count: 64)
            results[0] = .EventReceipt(receipt)
        }
        if case .responseCountDelta(let delta) = behavior {
            if delta < 0 { results.removeLast() } else { results.append(try #require(results.first)) }
        }
        if case .reverseResults = behavior { results.reverse() }
        if case .problemStatus(let code) = behavior { results[results.count - 1] = .ProblemDetails(.init(title: "Synthetic status", status: code)) }
        return results
    }

    private func admit(_ request: Components.Schemas.EventSubmission, sourceID: UUID) throws -> Components.Schemas.EventReceipt {
        let original = try #require(Data(base64Encoded: request.eventBase64))
        let commitment = try EventSubmissionCommitment(
            sourceID: sourceID,
            originalBytes: original,
            targets: request.targets.map { .init(consentID: try #require(UUID(uuidString: $0.consentId)), outputFullURLs: $0.outputFullUrls) }
        )
        var receipt = receipts[commitment.producerEventIdentifier.value] ?? .init(
            eventId: UUID().uuidString,
            sourceId: sourceID.uuidString.lowercased(),
            producerEventIdentifier: commitment.producerEventIdentifier,
            payloadSHA256: commitment.payloadSHA256,
            targetIntentSHA256: commitment.targetIntent.sha256,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            nodeCount: commitment.nodeCount
        )
        receipts[commitment.producerEventIdentifier.value] = receipt
        if case .mismatch = behavior { receipt.payloadSHA256 = String(repeating: "0", count: 64) }
        return receipt
    }

    private func encoded(_ receipt: some Encodable) throws -> (HTTPResponse, HTTPBody?) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(try encoder.encode(receipt)))
    }

    private func rejected(_ code: Int) -> (HTTPResponse, HTTPBody?) {
        let bytes = Data("{\"type\":\"about:blank\",\"title\":\"Synthetic Rejection\",\"status\":\(code)}".utf8)
        return (HTTPResponse(status: .init(code: code), headerFields: [.contentType: "application/problem+json"]), HTTPBody(bytes))
    }
}
