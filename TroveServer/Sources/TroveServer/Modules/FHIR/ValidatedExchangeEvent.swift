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

    struct Output: Sendable {
        let fullURL: String
        let profile: String
        var measurementBounds: ClinicalMeasurementBounds

        var effectiveAt: Date { measurementBounds.startDate }
        var effectiveEnd: Date? { measurementBounds.endDate }
        let sourceRecordIdentifier: Identifier
        let sourceOutputIdentifier: Identifier
        let writerIdentifier: Identifier?
        let writerVersion: String?
        let value: ClinicalOutputValue
        let codeSystem: String
        let code: String
        var sourceTypeIdentifier: String?
        var sourceRepositoryKind: SourceRepositoryKind?
        /// Row extremes of a query-created recording batch, verified against its complete content.
        var rowExtent: RecordingRowExtent?
    }

    struct Retraction: Sendable {
        let sourceRecordIdentifier: Identifier
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

    struct OutputDependency: Sendable, Hashable {
        enum Relation: String, Sendable {
            case derivedFrom
            case related
        }

        let outputFullURL: String
        let targetFullURL: String
        let relation: Relation
    }

    let rawBytes: Data
    var recorded: RecordedInstant
    let validatorIdentity: String
    let eventIdentifierSystem: String
    let eventIdentifierValue: String
    var deploymentIdentifiers: FHIRDeploymentIdentifiers
    let participants: Set<Identifier>
    let nodes: [Node]
    let outputs: [Output]
    var retraction: Retraction?
    /// Informative native UUID evidence, never a source authority or deduplication key.
    var nativeRecordIdentifiers: [Identifier] = []
    /// The readable HealthKit sync identifier, verbatim: informative evidence like the native UUID, never an identity,
    /// entry key, deduplication key, version selector, receipt or retraction target.
    var syncRecordIdentifiers: [Identifier] = []
    var recordings: [ClinicalRecordingAttachment] = []
    var questionnaireContexts: [QuestionnaireContext] = []
    var derivations: [Derivation] = []
    /// Producer graph dependencies preserve lineage but grant no access to the companion output.
    var outputDependencies: [OutputDependency] = []
}


extension ValidatedExchangeEvent {
    var collectionOutputs: [ClinicalGrantStore.Output] {
        // A summary derived from a query-created batch describes every row of its companion recording.
        let batchRows = outputs.compactMap(\.rowExtent)
        let sharedRows = batchRows.count == 1 && Set(outputs.map(\.sourceRecordIdentifier)).count == 1 ? batchRows.first : nil
        return outputs.map {
            .init(
                fullURL: $0.fullURL,
                profile: $0.profile,
                measurementBounds: $0.measurementBounds,
                codeSystem: $0.codeSystem,
                code: $0.code,
                sourceTypeIdentifier: $0.sourceTypeIdentifier,
                rowExtent: $0.rowExtent ?? sharedRows
            )
        }
    }
}
