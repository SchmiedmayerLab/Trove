//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
@testable import TroveServer


/// Synthetic replies of the validator's authoring routes, bound to the exact submitted bytes.
enum QuestionnaireWorkerReply {
    static let identity = "sha256:" + String(repeating: "a", count: 64)

    static func httpStatus(for status: ValidationStatus) -> Int {
        switch status {
        case .valid: 200
        case .invalid, .incomplete: 422
        case .unavailable: 503
        }
    }

    static func body(
        for bytes: Data,
        status: ValidationStatus = .valid,
        purpose: FHIRValidationClient.Purpose = .questionnaire,
        diagnostics: [ValidationDiagnostic] = [],
        omitted: Int? = nil,
        identity: String = identity
    ) throws -> Data {
        var payload: [String: Any] = [
            "status": status.rawValue,
            "sha256": FHIRValidationClient.digest(bytes),
            "contractRevision": FHIRValidationClient.contractRevision,
            "validatorIdentity": identity,
            "purpose": purpose.rawValue,
            "diagnostics": try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagnostics))
        ]
        if let omitted {
            payload["omittedDiagnostics"] = omitted
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    /// A validator whose authoring routes answer with `status`, and whose event route is never contacted.
    /// The response structure route's reply: `nil` code for a valid response, otherwise `invalid_fhir` or another code.
    static func structureBody(for bytes: Data, code: String? = nil, identity: String = identity) throws -> Data {
        var payload: [String: Any] = [
            "valid": code == nil,
            "sha256": FHIRValidationClient.digest(bytes),
            "contractRevision": FHIRValidationClient.contractRevision,
            "validatorIdentity": identity,
            "purpose": FHIRValidationClient.Purpose.questionnaireResponseStructure.rawValue
        ]
        if let code {
            payload["code"] = code
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    static func validator(
        status: ValidationStatus = .valid,
        diagnostics: [ValidationDiagnostic] = [],
        identity: String = identity,
        structure: ValidationStatus = .valid
    ) -> FHIRValidationClient {
        FHIRValidationClient(expectedIdentity: identity, sendForPurpose: { purpose, bytes in
            guard purpose != .event else { throw FHIRValidationClient.unavailable }
            if purpose == .questionnaireResponseStructure {
                switch structure {
                case .valid: return (200, try structureBody(for: bytes, identity: identity))
                case .invalid, .incomplete: return (422, try structureBody(for: bytes, code: "invalid_fhir", identity: identity))
                case .unavailable: return (503, try structureBody(for: bytes, code: "validator_unavailable", identity: identity))
                }
            }
            return (
                httpStatus(for: status),
                try body(for: bytes, status: status, purpose: purpose, diagnostics: diagnostics, identity: identity)
            )
        })
    }

    static func finding(
        _ rule: String, severity: ValidationDiagnostic.SeverityPayload = .error, path: String = "Questionnaire"
    ) -> ValidationDiagnostic {
        .init(severity: severity, source: .fhir, rule: rule, path: path, message: "Synthetic finding")
    }
}
