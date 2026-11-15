//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
import TroveAPIClient


/// Generated-client peer that consumes upload chunks without collecting them. Clinical admission is tested by the receiver.
actor RecordingTransferTransport: ClientTransport {
    enum Behavior { case accept, loseRegistration, loseUpload, mismatchedRegistration, mismatchedReceipt, unauthorized }
    private let transfer: DeliveryRecordingTransfer
    private var behavior: Behavior = .accept
    private var lostResponse = false
    private var receipt: Components.Schemas.RecordingTransferReceipt?
    private var onReply: (@Sendable () async -> Void)?
    private var onChunk: (@Sendable () async throws -> Void)?
    private(set) var operations: [String] = []
    private(set) var uploadByteCounts: [Int] = []
    private(set) var largestChunk = 0

    init(_ transfer: DeliveryRecordingTransfer) { self.transfer = transfer }

    func configure(_ behavior: Behavior) { self.behavior = behavior }
    func afterReply(_ action: @escaping @Sendable () async -> Void) { onReply = action }
    func duringUpload(_ action: @escaping @Sendable () async throws -> Void) { onChunk = action }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        #expect(baseURL.absoluteString == DeliveryFixture.scope.backend)
        #expect(request.path?.contains(transfer.transferID.uuidString.lowercased()) == true)
        operations.append(operationID)
        if behavior == .unauthorized {
            return rejected(401)
        }
        let reply: (HTTPResponse, HTTPBody?)
        switch operationID {
        case Operations.LookupParticipantRecordingTransferReceipt.id:
            #expect(body == nil)
            let header = try #require(HTTPField.Name("Trove-Source-Credential"))
            #expect(request.headerFields[header] == nil)
            reply = try receipt.map(encoded) ?? rejected(404)
        case Operations.DeclareParticipantRecordingTransfer.id:
            let body = try #require(body)
            let bytes = try await Data(collecting: body, upTo: RecordingTransferCommitment.maximumBytes)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { try TroveDateTranscoder().decode($0.singleValueContainer().decode(String.self)) }
            let declaration = try decoder.decode(Components.Schemas.RecordingTransferDeclaration.self, from: bytes)
            #expect(try RecordingTransferCommitment(declaration).sha256 == transfer.commitment.sha256)
            try verifyInstallation(request)
            var registration = RecordingDeliveryFixture.registration(transfer)
            if behavior == .mismatchedRegistration { registration.declarationSHA256 = String(repeating: "0", count: 64) }
            if behavior == .loseRegistration, !lostResponse {
                lostResponse = true
                throw URLError(.networkConnectionLost)
            }
            reply = try encoded(registration)
        case Operations.UploadParticipantRecordingTransfer.id:
            try verifyInstallation(request)
            reply = try await upload(#require(body))
        default:
            Issue.record("Unexpected recording operation")
            reply = rejected(400)
        }
        let action = onReply
        onReply = nil
        await action?()
        return reply
    }

    private func upload(_ body: HTTPBody) async throws -> (HTTPResponse, HTTPBody?) {
        #expect(body.length == .known(transfer.commitment.declaration.content.storedByteCount))
        var count = 0, digest = SHA256()
        for try await chunk in body {
            count += chunk.count
            largestChunk = max(largestChunk, chunk.count)
            digest.update(data: chunk)
            try await onChunk?()
        }
        #expect(Int64(count) == transfer.commitment.declaration.content.storedByteCount)
        #expect(digest.finalize().map { String(format: "%02x", $0) }.joined() == transfer.commitment.declaration.content.storedSHA256)
        #expect(largestChunk <= 64 * 1024)
        uploadByteCounts.append(count)
        let accepted = RecordingDeliveryFixture.receipt(transfer)
        receipt = accepted
        if behavior == .loseUpload, !lostResponse {
            lostResponse = true
            throw URLError(.networkConnectionLost)
        }
        var response = accepted
        if behavior == .mismatchedReceipt { response.storedByteCount += 1 }
        return try encoded(response)
    }

    private func verifyInstallation(_ request: HTTPRequest) throws {
        let name = try #require(HTTPField.Name("Trove-Source-Installation-ID"))
        let credential = try #require(HTTPField.Name("Trove-Source-Credential"))
        #expect(request.headerFields[name] == DeliveryFixture.epoch.uuidString.lowercased())
        #expect(request.headerFields[credential] != nil)
    }

    private func rejected(_ code: Int) -> (HTTPResponse, HTTPBody?) {
        let bytes = Data("{\"type\":\"about:blank\",\"title\":\"Synthetic Rejection\",\"status\":\(code)}".utf8)
        return (.init(status: .init(code: code), headerFields: [.contentType: "application/problem+json"]), .init(bytes))
    }

    private func encoded(_ value: some Encodable) throws -> (HTTPResponse, HTTPBody?) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(TroveDateTranscoder().encode(date))
        }
        return (.init(status: .ok, headerFields: [.contentType: "application/json"]), .init(try encoder.encode(value)))
    }
}
