//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveConsent
import PDFKit
import TroveAPIClient


struct ConsentExport: Equatable, Sendable {
    let responses: Components.Schemas.UserResponses
    let pdf: Data
}


@MainActor
enum ConsentExportBridge {
    static func export(_ document: ConsentDocument) throws -> ConsentExport {
        guard document.completionState == .complete else {
            throw ConsentFailure.incomplete
        }
        let result = try document.export(using: .init())
        guard let pdf = result.pdf.dataRepresentation(), !pdf.isEmpty else {
            throw ConsentFailure.preparationFailed
        }
        guard pdf.count <= PendingConsentCommand.maximumPDFBytes else {
            throw ConsentFailure.pdfTooLarge
        }
        return try .init(responses: responses(result.userResponses), pdf: pdf)
    }

    /// Codable preserves Grove's internal canvas size without reflection or invented dimensions.
    static func responses(_ responses: ConsentDocument.UserResponses) throws -> Components.Schemas.UserResponses {
        let encoded = try JSONEncoder().encode(responses)
        let converted = try JSONDecoder().decode(Components.Schemas.UserResponses.self, from: encoded)
        for signature in converted.signatures?.additionalProperties.values ?? [:].values {
            guard signature.size.count == 2, signature.size.allSatisfy({ $0.isFinite && $0 > 0 }),
                  let bytes = Data(base64Encoded: signature.signature), !bytes.isEmpty,
                  !(signature.name.givenName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !(signature.name.familyName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConsentFailure.incomplete
            }
        }
        return converted
    }
}
