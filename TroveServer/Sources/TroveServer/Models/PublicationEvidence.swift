//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
@_spi(APISupport) import GroveStudyDefinition


/// One published Questionnaire, its administration languages and the approval that admitted each of them.
struct PublishedInstrument: Codable, Sendable, Hashable {
    struct AdministrationLanguage: Codable, Sendable, Hashable {
        /// The administrator who approved the language. Kept with the publication and not returned by the API.
        struct Approver: Codable, Sendable, Hashable {
            let issuer: String
            let subject: String
        }

        let language: String
        let approvalID: UUID
        let approvedAt: Date
        let approvedBy: Approver
    }

    let componentID: UUID
    /// SHA-256 of the exact archived Questionnaire bytes.
    let sha256: String
    let language: String
    let translationLanguages: [String]
    let administrationLanguages: [AdministrationLanguage]
}


/// What a publication was validated with, recorded separately from its revision number.
///
/// The study definition schema version, the IG contract and the execution capability can each change in a later
/// release; a publication keeps the values it was accepted under.
struct PublicationEvidence: Codable, Sendable, Hashable {
    /// A document wrapper keeps PostgreSQL from storing the list as a native SQL array.
    struct Instruments: Codable, Sendable, Hashable {
        let instruments: [PublishedInstrument]
    }

    static var currentDefinitionSchemaVersion: String {
        "\(StudyDefinition.schemaVersion)"
    }

    let definitionSchemaVersion: String
    let contractVersion: String
    let contractRevision: String
    let validatorIdentity: String
    let executionCapability: String
    let instruments: [PublishedInstrument]
    let readinessFacts: StudyReadinessFacts
}
