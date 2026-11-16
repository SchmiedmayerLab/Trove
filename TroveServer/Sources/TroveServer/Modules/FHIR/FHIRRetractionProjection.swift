//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import ModelsR4


/// Whole-source-record retraction after complete pinned IG validation.
/// The record carries converter Devices but no clinical output; the registered source establishes authority.
enum FHIRRetractionProjection {
    static func project(bytes: Data, validatorIdentity: String) throws -> ValidatedExchangeEvent {
        let graph = try ExchangeGraph(validating: bytes, kind: .retraction)
        let record = try ExchangeRecord(validating: bytes)
        try FHIRPointSupportBoundary.validateExtensionLocations(in: bytes)
        guard record.kind == .retraction, record.outputFullURLs.isEmpty,
              let entries = graph.bundle.entry, (1...512).contains(entries.count) else { throw FHIRValidationClient.invalid }
        let (nodes, resources) = try FHIRPointProjection.index(entries)
        try FHIRPointSupportBoundary.validate(resources: resources)
        guard nodes.filter({ $0.resourceType == "Provenance" }).count == 1,
              nodes.allSatisfy({ $0.resourceType == "Provenance" || $0.resourceType == "Device" }) else {
            throw FHIRValidationClient.invalid
        }
        let identity = record.version.identifier.identifier
        let result = ValidatedExchangeEvent(
            rawBytes: bytes,
            recorded: try RecordedInstant.extract(from: resources),
            validatorIdentity: validatorIdentity,
            eventIdentifierSystem: identity.system.rawValue,
            eventIdentifierValue: identity.value,
            deploymentIdentifiers: try JSONDecoder().decode(FHIRDeploymentIdentifiers.self, from: bytes),
            participants: [],
            nodes: nodes,
            outputs: [],
            retraction: .init(sourceRecordIdentifier: .init(system: record.sourceRecord.system.rawValue, value: record.sourceRecord.value))
        )
        _ = try ClinicalRecordRevision(result)
        return result
    }
}
