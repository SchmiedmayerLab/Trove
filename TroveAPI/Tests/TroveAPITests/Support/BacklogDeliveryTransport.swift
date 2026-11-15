//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import HTTPTypes
import OpenAPIRuntime
import Testing
import TroveAPIClient


/// Synthetic peer retaining receipts/counters only. Unlike DeliveryTransport, it never
/// retains submitted payloads, packed Bundles or Base64 bodies across HTTP requests.
/// This exercises generated transport/receipt behavior, not receiver or full-IG acceptance.
actor BacklogDeliveryTransport: ClientTransport {
    struct Snapshot: Sendable {
        let submittedRecords: Int
        let acceptedRecords: Int
        let duplicateSubmissions: Int
        let lookupRequests: Int
        let submittedEnvelopeBytes: Int
        let maximumEnvelopeBytes: Int
        let maximumBundleBytes: Int
        let maximumBatchRecords: Int
    }

    private var receipts: [String: Components.Schemas.EventReceipt] = [:]
    private var submittedRecords = 0
    private var duplicateSubmissions = 0
    private var lookupRequests = 0
    private var submittedEnvelopeBytes = 0
    private var maximumEnvelopeBytes = 0
    private var maximumBundleBytes = 0
    private var maximumBatchRecords = 0
    private var droppedResponse = false
    private var secondLookup: (@Sendable () async throws -> Void)?

    func onSecondLookup(_ action: @escaping @Sendable () async throws -> Void) {
        secondLookup = action
    }

    func snapshot() -> Snapshot {
        Snapshot(
            submittedRecords: submittedRecords,
            acceptedRecords: receipts.count,
            duplicateSubmissions: duplicateSubmissions,
            lookupRequests: lookupRequests,
            submittedEnvelopeBytes: submittedEnvelopeBytes,
            maximumEnvelopeBytes: maximumEnvelopeBytes,
            maximumBundleBytes: maximumBundleBytes,
            maximumBatchRecords: maximumBatchRecords
        )
    }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        let body = try #require(body)
        let bytes = try await Data(collecting: body, upTo: EventSubmissionLimits.maximumEnvelopeBytes)
        let path = try #require(request.path)
        #expect(baseURL.absoluteString == DeliveryFixture.scope.backend)
        if path.hasSuffix("/event-receipts/lookup") {
            lookupRequests += 1
            let lookup = try JSONDecoder().decode(Components.Schemas.EventReceiptLookup.self, from: bytes)
            let receipt = try #require(receipts[lookup.producerEventIdentifier.value])
            #expect(lookup.payloadSHA256 == receipt.payloadSHA256)
            if lookupRequests == 2 {
                let action = secondLookup
                secondLookup = nil
                try await action?()
            }
            return try encoded(receipt)
        }
        #expect(path.hasSuffix("/record-bundles"))
        return try submit(bytes)
    }

    private func submit(_ bytes: Data) throws -> (HTTPResponse, HTTPBody?) {
        let submission = try JSONDecoder().decode(Components.Schemas.RecordBundleSubmission.self, from: bytes)
        let packed = try #require(Data(base64Encoded: submission.bundleBase64))
        let graph = try ExchangeGraph(validating: packed, kind: .active)
        let records = try graph.records()
        submittedEnvelopeBytes += bytes.count
        maximumEnvelopeBytes = max(maximumEnvelopeBytes, bytes.count)
        maximumBundleBytes = max(maximumBundleBytes, packed.count)
        maximumBatchRecords = max(maximumBatchRecords, submission.records.count)
        var results: [Components.Schemas.EventBatchResult] = []
        for member in submission.records {
            let record = try #require(records.first {
                $0.version.identifier.identifier.system.rawValue == member.commitment.producerEventIdentifier.system
                    && $0.version.identifier.identifier.value == member.commitment.producerEventIdentifier.value
            })
            let original = try ExchangeRecordBytes(record).restoring(entryFullURLs: member.entryFullUrls)
            let commitment = try EventSubmissionCommitment(
                sourceID: DeliveryFixture.sourceID,
                originalBytes: original.json,
                targets: member.commitment.targets.map {
                    .init(consentID: try #require(UUID(uuidString: $0.consentId)), outputFullURLs: $0.outputFullUrls)
                }
            )
            #expect(commitment.payloadSHA256 == member.commitment.payloadSHA256)
            let key = commitment.producerEventIdentifier.value
            submittedRecords += 1
            if receipts[key] != nil { duplicateSubmissions += 1 }
            let receipt = receipts[key] ?? Components.Schemas.EventReceipt(
                eventId: UUID().uuidString,
                sourceId: DeliveryFixture.sourceID.uuidString.lowercased(),
                producerEventIdentifier: commitment.producerEventIdentifier,
                payloadSHA256: commitment.payloadSHA256,
                targetIntentSHA256: commitment.targetIntent.sha256,
                receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
                nodeCount: commitment.nodeCount
            )
            receipts[key] = receipt
            results.append(.EventReceipt(receipt))
        }
        if !droppedResponse {
            droppedResponse = true
            throw URLError(.networkConnectionLost)
        }
        return try encoded(results)
    }

    private func encoded(_ value: some Encodable) throws -> (HTTPResponse, HTTPBody?) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(try encoder.encode(value)))
    }
}
