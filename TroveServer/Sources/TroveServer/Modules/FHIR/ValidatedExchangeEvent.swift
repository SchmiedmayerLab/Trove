//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation


/// Immutable custody acknowledgement, never a claim about current study access.
struct ClinicalEventReceipt: Sendable, Equatable {
    let eventID: UUID
    let sourceID: UUID
    let producerEventIdentifier: ValidatedExchangeEvent.Identifier
    let payloadSHA256: String
    let targetIntentSHA256: String
    let receivedAt: Date
    let nodeCount: Int
}
/// Internal projection produced only after complete pinned validation of these exact bytes.
/// This value is not a request DTO and conveys no participant or study authorization.
struct ValidatedExchangeEvent: Sendable {
    struct Identifier: Sendable, Hashable {
        let system: String
        let value: String

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.system.utf8.elementsEqual(rhs.system.utf8) && lhs.value.utf8.elementsEqual(rhs.value.utf8)
        }

        func hash(into hasher: inout Hasher) {
            // String equality folds canonical Unicode equivalents; complete exchange identities do not.
            hasher.combine(system.utf8.count)
            for byte in system.utf8 { hasher.combine(byte) }
            hasher.combine(value.utf8.count)
            for byte in value.utf8 { hasher.combine(byte) }
        }
    }

    struct Node: Sendable {
        let ordinal: Int
        let fullURL: String
        let resourceType: String
    }

    struct PointOutput: Sendable {
        let fullURL: String
        let profile: String
        let effectiveAt: Date
        let sourceRecordIdentifier: Identifier
        let sourceOutputIdentifier: Identifier
        let writerIdentifier: Identifier?
        let writerVersion: String?
        /// Lossless decimal text; no binary floating-point research projection.
        let quantityValue: String
        let quantitySystem: String
        let quantityCode: String
        let codeSystem: String
        let code: String
    }

    struct Retraction: Sendable {
        let sourceRecordIdentifier: Identifier
        let outputIdentifiers: [Identifier]
    }

    struct QuestionnaireContext: Sendable {
        let fullURL: String
        let identifier: Identifier
    }

    struct Derivation: Sendable {
        enum Target: Sendable, Hashable {
            case local(String)
            case logical(Identifier)
        }

        let outputFullURL: String
        let target: Target
    }

    let rawBytes: Data
    let validatorIdentity: String
    let eventIdentifierSystem: String
    let eventIdentifierValue: String
    let producerInstance: UUID
    let participants: Set<Identifier>
    let nodes: [Node]
    let outputs: [PointOutput]
    var retraction: Retraction?
    var questionnaireContexts: [QuestionnaireContext] = []
    var derivations: [Derivation] = []
}
