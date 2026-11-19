//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation
import Testing
@testable import TroveServer


struct FHIRValidationClientTests {
    private static let identity = "sha256:" + String(repeating: "a", count: 64)
    private static let bytes = Data("exact original bytes".utf8)

    @Test
    func onlyExactPinnedSuccessAdmitsTheOriginalBytes() async throws {
        let validator = FHIRValidationClient(expectedIdentity: Self.identity) { input in
            #expect(input == Self.bytes)
            return (200, try Self.reply())
        }
        #expect(try await validator.validate(Self.bytes) == Self.identity)
    }

    @Test(arguments: ["digest", "revision", "identity", "false", "code", "oversized", "malformed", "redirect", "unavailable"])
    func untrustedOrIncompleteResultFailsClosed(change: String) async throws {
        let validator = FHIRValidationClient(expectedIdentity: Self.identity) { _ in
            switch change {
            case "oversized": return (200, Data(repeating: 32, count: 2049))
            case "malformed": return (200, Data("{}".utf8))
            case "redirect": return (302, try Self.reply())
            case "unavailable": return (503, try Self.reply())
            default: return (200, try Self.reply(change: change))
            }
        }
        await #expect {
            try await validator.validate(Self.bytes)
        } throws: { ($0 as? ServerError)?.status.code == 503 }
    }

    @Test
    func pinnedInvalidResultIsAValidationRefusal() async throws {
        let validator = FHIRValidationClient(expectedIdentity: Self.identity) { _ in
            (422, try Self.reply(change: "invalid"))
        }
        await #expect {
            try await validator.validate(Self.bytes)
        } throws: { ($0 as? ServerError)?.status.code == 422 }
    }

    @Test(arguments: [nil, "", "sha256:missing", "sha256:" + String(repeating: "A", count: 64)])
    func missingOrMalformedPinNeverContactsWorker(identity: String?) async throws {
        let validator = FHIRValidationClient(expectedIdentity: identity) { _ in
            Issue.record("Unpinned worker must never receive clinical bytes")
            return (200, Data())
        }
        await #expect {
            try await validator.validate(Self.bytes)
        } throws: { ($0 as? ServerError)?.status.code == 503 }
    }

    @Test(arguments: [0, FHIRValidationClient.maximumBytes + 1])
    func inputBoundsAreCheckedBeforeWorker(size: Int) async throws {
        let validator = FHIRValidationClient(expectedIdentity: Self.identity) { _ in
            Issue.record("Invalid input length must not reach worker")
            return (200, Data())
        }
        await #expect {
            try await validator.validate(Data(repeating: 32, count: size))
        } throws: { ($0 as? ServerError)?.status.code == (size == 0 ? 422 : 413) }
    }

    @Test
    func cancellationIsNotReportedAsInvalidFHIR() async throws {
        let validator = FHIRValidationClient(expectedIdentity: Self.identity) { _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) { try await validator.validate(Self.bytes) }
    }

    @Test(arguments: [ValidationStatus.valid, .invalid, .incomplete])
    func questionnaireResultCarriesTheWorkerFindingsBoundToItsPurpose(status: ValidationStatus) async throws {
        let findings = [
            QuestionnaireWorkerReply.finding("Synthetic_Error", severity: status == .invalid ? .error : .warning, path: "Questionnaire.item[0]")
        ]
        let validator = FHIRValidationClient(expectedIdentity: Self.identity, sendForPurpose: { purpose, input in
            #expect(purpose == .questionnaire)
            #expect(input == Self.bytes)
            return (QuestionnaireWorkerReply.httpStatus(for: status), try QuestionnaireWorkerReply.body(
                for: input, status: status, diagnostics: findings, identity: Self.identity
            ))
        })
        let result = try await validator.validateQuestionnaire(Self.bytes)
        #expect(result.status == status)
        #expect(result.diagnostics == findings)
        #expect(result.validatorIdentity == Self.identity)
    }

    @Test(arguments: [
        "event", "response", "digest", "revision", "identity", "http", "valid-with-error", "invalid-without-error",
        "incomplete-with-error", "too-many", "zero-omitted", "malformed", "oversized", "unavailable", "transport"
    ])
    func questionnaireReplyThatIsNotBoundOrConsistentIsUnavailable(change: String) async throws { // swiftlint:disable:this cyclomatic_complexity
        let validator = FHIRValidationClient(expectedIdentity: Self.identity, sendForPurpose: { _, input in
            let error = QuestionnaireWorkerReply.finding("Synthetic_Error")
            func reply(
                _ status: ValidationStatus,
                bytes: Data = input,
                purpose: FHIRValidationClient.Purpose = .questionnaire,
                diagnostics: [ValidationDiagnostic] = [],
                omitted: Int? = nil,
                identity: String = Self.identity
            ) throws -> Data {
                var body = try JSONSerialization.jsonObject(with: QuestionnaireWorkerReply.body(
                    for: bytes, status: status, purpose: purpose, diagnostics: diagnostics, omitted: omitted, identity: identity
                )) as? [String: Any] ?? [:]
                if change == "revision" { body["contractRevision"] = "wrong" }
                return try JSONSerialization.data(withJSONObject: body)
            }
            switch change {
            case "event": return (200, try reply(.valid, purpose: .event))
            case "response": return (200, try reply(.valid, purpose: .questionnaireResponse))
            case "digest": return (200, try reply(.valid, bytes: Data("other".utf8)))
            case "revision": return (200, try reply(.valid))
            case "identity": return (200, try reply(.valid, identity: "sha256:" + String(repeating: "b", count: 64)))
            case "http": return (200, try reply(.invalid, diagnostics: [error]))
            case "valid-with-error": return (200, try reply(.valid, diagnostics: [error]))
            case "invalid-without-error": return (422, try reply(.invalid))
            case "incomplete-with-error": return (422, try reply(.incomplete, diagnostics: [error]))
            case "too-many": return (422, try reply(.invalid, diagnostics: Array(repeating: error, count: 101)))
            case "zero-omitted": return (422, try reply(.invalid, diagnostics: [error], omitted: 0))
            case "malformed": return (200, Data("{}".utf8))
            case "oversized": return (200, Data(repeating: 32, count: FHIRValidationClient.maximumAuthoringReplyBytes + 1))
            case "unavailable": return (503, try reply(.unavailable))
            default: throw FHIRValidationClient.unavailable
            }
        })
        let result = try await validator.validateQuestionnaire(Self.bytes)
        #expect(result.status == .unavailable)
        #expect(result.diagnostics.isEmpty)
    }

    @Test
    func omittedWorkerFindingsAreStated() async throws {
        let validator = FHIRValidationClient(expectedIdentity: Self.identity, sendForPurpose: { _, input in
            (422, try QuestionnaireWorkerReply.body(
                for: input, status: .invalid, diagnostics: [QuestionnaireWorkerReply.finding("Synthetic_Error")], omitted: 7, identity: Self.identity
            ))
        })
        let result = try await validator.validateQuestionnaire(Self.bytes)
        #expect(result.status == .invalid)
        #expect(result.diagnostics.last?.rule == "diagnostics-omitted")
        #expect(result.diagnostics.last?.message.contains("7") == true)
    }

    @Test
    func questionnaireReplyNeverAdmitsAnExchangeEvent() async throws {
        let validator = FHIRValidationClient(expectedIdentity: Self.identity) { input in
            (200, try QuestionnaireWorkerReply.body(for: input, identity: Self.identity))
        }
        await #expect {
            try await validator.validate(Self.bytes)
        } throws: { ($0 as? ServerError)?.status.code == 503 }
    }

    @Test
    func eventOnlyTransportCannotValidateQuestionnaires() async throws {
        let validator = FHIRValidationClient(expectedIdentity: Self.identity) { _ in
            Issue.record("An event-only transport must never receive authoring content")
            return (200, try Self.reply())
        }
        #expect(try await validator.validateQuestionnaire(Self.bytes).status == .unavailable)
    }

    @Test(arguments: [nil, "sha256:missing"])
    func unpinnedValidatorNeverReceivesAuthoringContent(identity: String?) async throws {
        let validator = FHIRValidationClient(expectedIdentity: identity, sendForPurpose: { _, _ in
            Issue.record("An unpinned worker must never receive authoring content")
            return (200, Data())
        })
        #expect(try await validator.validateQuestionnaire(Self.bytes).status == .unavailable)
    }

    @Test(arguments: [0, 4 * 1024 * 1024 + 1])
    func questionnaireInputBoundsPreventTransport(size: Int) async throws {
        let validator = FHIRValidationClient(expectedIdentity: Self.identity, sendForPurpose: { _, _ in
            Issue.record("Invalid input length must not reach worker")
            return (200, Data())
        })
        let result = try await validator.validateQuestionnaire(Data(repeating: 32, count: size))
        #expect(result.status == .invalid)
        #expect(result.diagnostics.map(\.rule) == ["size-limit"])
    }

    @Test
    func responseValidationSendsOnePairBundleEmbeddingBothExactDocuments() async throws {
        let questionnaire = Data(#"{"resourceType":"Questionnaire", "id" : "q"}"#.utf8)
        let response = Data(#"{"resourceType":"QuestionnaireResponse","id":"r"}"#.utf8)
        let validator = FHIRValidationClient(expectedIdentity: Self.identity, sendForPurpose: { purpose, input in
            #expect(purpose == .questionnaireResponse)
            let text = String(decoding: input, as: UTF8.self)
            #expect(text == #"{"resourceType":"Bundle","type":"collection","entry":[{"resource":"#
                + String(decoding: questionnaire, as: UTF8.self) + #"},{"resource":"# + String(decoding: response, as: UTF8.self) + "}]}")
            return (200, try QuestionnaireWorkerReply.body(for: input, purpose: .questionnaireResponse, identity: Self.identity))
        })
        #expect(try await validator.validateQuestionnaireResponse(questionnaire: questionnaire, response: response).status == .valid)
    }

    @Test(arguments: [
        (#"{"resourceType":"Questionnaire","title":"abc"#, #""}},{"resource":{"resourceType":"QuestionnaireResponse"}"#),
        (#"{"resourceType":"Questionnaire"}"#, #"{"resourceType":"QuestionnaireResponse"}, {}"#),
        (#"[]"#, #"{"resourceType":"QuestionnaireResponse"}"#)
    ])
    func responseValidationRefusesDocumentsThatAreNotEachOneObject(questionnaire: String, response: String) async throws {
        let validator = FHIRValidationClient(expectedIdentity: Self.identity, sendForPurpose: { _, _ in
            Issue.record("A document that could break out of the pair framing must not reach the worker")
            return (200, Data())
        })
        let result = try await validator.validateQuestionnaireResponse(questionnaire: Data(questionnaire.utf8), response: Data(response.utf8))
        #expect(result.status == .invalid)
        #expect(result.diagnostics.map(\.rule) == ["pair-input"])
    }

    @Test
    func cancelledAuthoringValidationIsNotReportedAsUnavailable() async throws {
        let validator = FHIRValidationClient(expectedIdentity: Self.identity, sendForPurpose: { _, _ in throw CancellationError() })
        await #expect(throws: CancellationError.self) { try await validator.validateQuestionnaire(Self.bytes) }
    }
}


extension FHIRValidationClientTests {
    private static func reply(change: String = "", purpose: String? = nil) throws -> Data {
        var payload: [String: Any] = [
            "valid": change != "false" && change != "invalid",
            "sha256": change == "digest" ? "wrong" : SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            "contractRevision": change == "revision" ? "wrong" : FHIRValidationClient.contractRevision,
            "validatorIdentity": change == "identity" ? "wrong" : identity
        ]
        if change == "code" || change == "invalid" { payload["code"] = "invalid_fhir" }
        if let purpose { payload["purpose"] = purpose }
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }
}
