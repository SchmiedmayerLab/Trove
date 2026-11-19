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
        case questionnaireResponse = "questionnaire-response"

        var route: String {
            switch self {
            case .event: ""
            case .questionnaire: "/questionnaire"
            case .questionnaireResponse: "/questionnaire-response"
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

    /// The validator's findings for authoring content: one questionnaire, or one questionnaire and response pair.
    struct AuthoringResult: Sendable {
        let status: ValidationStatus
        let diagnostics: [ValidationDiagnostic]
        /// The configured identity, when one is configured, whatever the status.
        let validatorIdentity: String?
    }

    private struct AuthoringReply: Decodable {
        let status: ValidationStatus
        let sha256: String
        let contractRevision: String
        let validatorIdentity: String
        let purpose: Purpose
        let diagnostics: [ValidationDiagnostic]
        let omittedDiagnostics: Int?
    }

    static let contractVersion = "0.8.2"
    static let contractRevision = "8c18d9b8ba36eff3f6003c65cdc9cae74a6d3228"
    static let maximumBytes = EventSubmissionLimits.maximumEventBytes
    /// Matches the worker's `MAX_REPLY` and `MAX_DIAGNOSTICS`.
    static let maximumAuthoringReplyBytes = 256 * 1024
    static let maximumWorkerDiagnostics = 100
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
            var request = HTTPClientRequest(url: endpoint + purpose.route)
            request.method = .POST
            request.headers = ["Content-Type": "application/fhir+json"]
            request.body = .bytes(ByteBuffer(data: bytes))
            let response = try await client.execute(request, timeout: .seconds(130))
            let limit = purpose == .event ? 2048 : Self.maximumAuthoringReplyBytes
            return (Int(response.status.code), Data(try await response.body.collect(upTo: limit).readableBytesView))
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

    static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func validate(_ bytes: Data) async throws -> String {
        guard bytes.count <= Self.maximumBytes else { throw Self.tooLarge }
        guard !bytes.isEmpty else { throw Self.invalid }
        let expectedIdentity = try requireIdentity()
        let (status, data) = try await exchange(bytes, purpose: .event)
        guard data.count <= 2048, let reply = try? JSONDecoder().decode(Reply.self, from: data),
              reply.sha256 == Self.digest(bytes),
              reply.contractRevision == Self.contractRevision, reply.validatorIdentity == expectedIdentity,
              reply.purpose == nil else {
            throw Self.unavailable
        }
        if status == 422 && !reply.valid && ["invalid_json", "invalid_fhir"].contains(reply.code) {
            throw Self.invalid
        }
        guard status == 200, reply.valid, reply.code == nil else { throw Self.unavailable }
        return expectedIdentity
    }

    /// Validates one Questionnaire's exact bytes. Only `valid` establishes validity.
    func validateQuestionnaire(_ bytes: Data) async throws -> AuthoringResult {
        try await validateAuthoring(bytes, purpose: .questionnaire)
    }

    /// Validates a response against its exact Questionnaire with the official validator.
    ///
    /// The worker receives one collection Bundle that embeds both documents byte for byte, so the response's canonical
    /// resolves only to these Questionnaire bytes. Each document must be exactly one JSON object on its own; otherwise
    /// one document could close the framing and supply the other.
    func validateQuestionnaireResponse(questionnaire: Data, response: Data) async throws -> AuthoringResult {
        guard [questionnaire, response].allSatisfy({ (try? JSONSerialization.jsonObject(with: $0)) is [String: Any] }) else {
            let finding = ValidationDiagnostic.trove(
                "pair-input", path: "", message: "The Questionnaire and the QuestionnaireResponse must each be one JSON object."
            )
            return .init(status: .invalid, diagnostics: [finding], validatorIdentity: expectedIdentity)
        }
        var bundle = Data(#"{"resourceType":"Bundle","type":"collection","entry":[{"resource":"#.utf8)
        bundle.append(questionnaire)
        bundle.append(Data(#"},{"resource":"#.utf8))
        bundle.append(response)
        bundle.append(Data("}]}".utf8))
        return try await validateAuthoring(bundle, purpose: .questionnaireResponse)
    }

    func requireIdentity() throws -> String {
        guard let expectedIdentity, expectedIdentity.hasPrefix("sha256:"),
              expectedIdentity.dropFirst(7).count == 64,
              expectedIdentity.dropFirst(7).allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw Self.unavailable
        }
        return expectedIdentity
    }

    private func validateAuthoring(_ bytes: Data, purpose: Purpose) async throws -> AuthoringResult {
        let limit = purpose == .questionnaire ? EventSubmissionLimits.Configuration.standard.recordBytes : Self.maximumBytes
        guard !bytes.isEmpty, bytes.count <= limit else {
            let finding = ValidationDiagnostic.trove(
                "size-limit", path: "", message: "The resource is empty or larger than the \(limit / 1024 / 1024) MiB validation limit."
            )
            return .init(status: .invalid, diagnostics: [finding], validatorIdentity: expectedIdentity)
        }
        let unavailable = AuthoringResult(status: .unavailable, diagnostics: [], validatorIdentity: expectedIdentity)
        guard let expectedIdentity = try? requireIdentity(),
              let exchanged = try await exchangeIfAvailable(bytes, purpose: purpose) else {
            return unavailable
        }
        let (status, data) = exchanged
        // Only a reply bound to these bytes, pins and purpose, with findings consistent with its status, is a result.
        guard data.count <= Self.maximumAuthoringReplyBytes,
              let reply = try? JSONDecoder().decode(AuthoringReply.self, from: data),
              reply.sha256 == Self.digest(bytes), reply.contractRevision == Self.contractRevision,
              reply.validatorIdentity == expectedIdentity, reply.purpose == purpose,
              reply.diagnostics.count <= Self.maximumWorkerDiagnostics, (reply.omittedDiagnostics ?? 1) > 0 else {
            return unavailable
        }
        let hasErrors = reply.diagnostics.contains { $0.severity == .error }
        switch (status, reply.status) {
        case (200, .valid) where !hasErrors, (422, .invalid) where hasErrors, (422, .incomplete) where !hasErrors:
            var diagnostics = reply.diagnostics
            if let omitted = reply.omittedDiagnostics, omitted > 0 {
                diagnostics.append(.trove(
                    "diagnostics-omitted", path: "", message: "\(omitted) further findings are not shown.", severity: .information
                ))
            }
            return .init(status: reply.status, diagnostics: diagnostics, validatorIdentity: expectedIdentity)
        default:
            return unavailable
        }
    }

    /// `nil` when the worker cannot be reached; only cancellation throws.
    private func exchangeIfAvailable(_ bytes: Data, purpose: Purpose) async throws -> (Int, Data)? {
        do {
            return try await exchange(bytes, purpose: purpose)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private func exchange(_ bytes: Data, purpose: Purpose) async throws -> (Int, Data) {
        do {
            let result = try await send(purpose, bytes)
            try Task.checkCancellation()
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Transport errors can contain addresses or remote response data. Do not surface them.
            throw Self.unavailable
        }
    }
}
