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
    static func validator(
        status: ValidationStatus = .valid,
        diagnostics: [ValidationDiagnostic] = [],
        identity: String = identity
    ) -> FHIRValidationClient {
        FHIRValidationClient(expectedIdentity: identity, sendForPurpose: { purpose, bytes in
            guard purpose != .event else { throw FHIRValidationClient.unavailable }
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
