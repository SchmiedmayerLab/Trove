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


/// Receiver support for restrictive Observation assertions after full pinned IG validation.
/// The graph has no patient payload; authentication and the source binding establish its scope.
enum FHIRRetractionProjection {
    static func project(bytes: Data, validatorIdentity: String) throws -> ValidatedExchangeEvent {
        let graph = try ExchangeGraph(validating: bytes, kind: .retraction)
        try FHIRPointSupportBoundary.validateExtensionLocations(in: bytes)
        guard let entries = graph.bundle.entry, entries.count == 1,
              let fullURL = entries[0].fullUrl?.value?.url.absoluteString,
              case .provenance(let provenance)? = entries[0].resource,
              provenance.contained?.isEmpty != false, provenance.modifierExtension?.isEmpty != false,
              provenance.extension?.isEmpty != false, provenance.implicitRules == nil,
              provenance.location == nil, provenance.signature?.isEmpty != false,
              provenance.agent.count == 1, provenance.agent[0].onBehalfOf == nil,
              provenance.agent[0].who.reference == nil,
              let entity = provenance.entity, entity.count == 1,
              entity[0].agent?.isEmpty != false,
              let source = entity[0].what.identifier else { throw FHIRValidationClient.invalid }
        let record = try RoledIdentifier(source)
        guard record.role == .sourceRecord else { throw FHIRValidationClient.invalid }
        let targets = try provenance.target.map { target -> ValidatedExchangeEvent.Identifier in
            guard target.type?.value?.url.absoluteString == "Observation", target.reference == nil,
                  let identifier = target.identifier,
                  (target.extension ?? []).allSatisfy({
                      $0.url == Canonicals.retractionTargetRole || $0.url == Canonicals.retractionTargetNativeIdentifier
                  }) else { throw FHIRValidationClient.invalid }
            let identifierValue = try RoledIdentifier(identifier)
            guard identifierValue.role == .sourceOutput else { throw FHIRValidationClient.invalid }
            return .init(system: identifierValue.identifier.system.rawValue, value: identifierValue.identifier.value)
        }
        let identity = graph.event
        let result = ValidatedExchangeEvent(
            rawBytes: bytes,
            validatorIdentity: validatorIdentity,
            eventIdentifierSystem: identity.system.rawValue,
            eventIdentifierValue: identity.value,
            producerInstance: graph.eventIdentifier.producerInstance,
            participants: [],
            nodes: [.init(ordinal: 0, fullURL: fullURL, resourceType: "Provenance")],
            outputs: [],
            retraction: .init(
                sourceRecordIdentifier: .init(system: record.identifier.system.rawValue, value: record.identifier.value), outputIdentifiers: targets
            )
        )
        _ = try ClinicalRecordRevision(result)
        return result
    }
}
