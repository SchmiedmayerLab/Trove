//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import AsyncHTTPClient
import Crypto
import Foundation
import TroveAPIServer
import Vapor


/// A private, pinned validation service validates the complete IG before local model decoding.
/// Neither its address nor its expected identity may come from a participant request.
struct FHIRValidationClient: Sendable {
    enum Purpose: String, Codable, Sendable {
        case event
        case questionnaire

        var invalid: ServerError {
            switch self {
            case .event: FHIRValidationClient.invalid
            case .questionnaire: .init(status: .unprocessableContent, title: "Invalid Questionnaire", detail: "Invalid Grove FHIR Questionnaire")
            }
        }

        var tooLarge: ServerError {
            switch self {
            case .event: FHIRValidationClient.tooLarge
            case .questionnaire:
                .init(status: .contentTooLarge, title: "Questionnaire Too Large", detail: "Questionnaire exceeds the validation size limit")
            }
        }
    }

    struct Reply: Decodable, Sendable {
        let valid: Bool
        let sha256: String
        let contractRevision: String
        let validatorIdentity: String
        let code: String?
        let purpose: Purpose?
    }

    static let contractRevision = "444e06fb25680c3af29e5d3ccbebeb0249be7318"
    static let maximumBytes = EventSubmissionLimits.maximumEventBytes
    static let unavailable = ServerError(status: .serviceUnavailable, title: "Validation Unavailable", detail: "Try again later")
    static let invalid = ServerError(status: .unprocessableContent, title: "Invalid Event", detail: "Invalid or unsupported Grove FHIR event")
    static let tooLarge = ServerError(status: .contentTooLarge, title: "Event Too Large", detail: "Event exceeds the admission size limit")

    let expectedIdentity: String?
    private let send: @Sendable (Purpose, Data) async throws -> (Int, Data)

    init(
        application: Application,
        endpoint: String? = Environment.get("FHIR_VALIDATOR_URL"),
        identity: String? = Environment.get("FHIR_VALIDATOR_IDENTITY")
    ) throws {
        let transport = try application.outboundTransport
        if let endpoint {
            guard try transport.validateEndpoint(endpoint).path == "/validate" else {
                throw OutboundTransportConfiguration.Failure.invalidEndpoint
            }
        }
        self.expectedIdentity = identity
        let client = application.http.client.shared
        self.send = { purpose, bytes in
            guard let endpoint else { throw Self.unavailable }
            let destination = purpose == .questionnaire ? endpoint + "/questionnaire" : endpoint
            var request = HTTPClientRequest(url: destination)
            request.method = .POST
            request.headers = ["Content-Type": "application/fhir+json"]
            request.body = .bytes(ByteBuffer(data: bytes))
            let response = try await client.execute(request, timeout: .seconds(130))
            return (Int(response.status.code), Data(try await response.body.collect(upTo: 2048).readableBytesView))
        }
    }

    /// Injectable transport for boundary tests; production uses the application-owned HTTP client.
    init(expectedIdentity: String?, send: @escaping @Sendable (Data) async throws -> (Int, Data)) {
        self.expectedIdentity = expectedIdentity
        self.send = { purpose, bytes in
            guard purpose == .event else { throw Self.unavailable }
            return try await send(bytes)
        }
    }

    init(expectedIdentity: String?, sendForPurpose: @escaping @Sendable (Purpose, Data) async throws -> (Int, Data)) {
        self.expectedIdentity = expectedIdentity
        self.send = sendForPurpose
    }

    func validate(_ bytes: Data) async throws -> String {
        try await validate(bytes, purpose: .event)
    }

    func validateQuestionnaire(_ bytes: Data) async throws -> String {
        try await validate(bytes, purpose: .questionnaire)
    }

    func requireIdentity() throws -> String {
        guard let expectedIdentity, expectedIdentity.hasPrefix("sha256:"),
              expectedIdentity.dropFirst(7).count == 64,
              expectedIdentity.dropFirst(7).allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw Self.unavailable
        }
        return expectedIdentity
    }

    private func validate(_ bytes: Data, purpose: Purpose) async throws -> String {
        guard bytes.count <= Self.maximumBytes else { throw purpose.tooLarge }
        guard !bytes.isEmpty else { throw purpose.invalid }
        let expectedIdentity = try requireIdentity()
        let status: Int
        let data: Data
        do {
            (status, data) = try await send(purpose, bytes)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Transport errors can contain addresses or remote response data. Do not surface them.
            throw Self.unavailable
        }
        guard data.count <= 2048, let reply = try? JSONDecoder().decode(Reply.self, from: data),
              reply.sha256 == SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined(),
              reply.contractRevision == Self.contractRevision, reply.validatorIdentity == expectedIdentity,
              reply.purpose == (purpose == .questionnaire ? .questionnaire : nil) else {
            throw Self.unavailable
        }
        if status == 422 && !reply.valid && ["invalid_json", "invalid_fhir"].contains(reply.code) {
            throw purpose.invalid
        }
        guard status == 200, reply.valid, reply.code == nil else { throw Self.unavailable }
        return expectedIdentity
    }
}
