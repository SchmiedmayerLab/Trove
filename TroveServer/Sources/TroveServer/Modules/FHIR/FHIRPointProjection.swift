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


/// Extracts the supported immutable point subset only AFTER complete validation of the exact bytes.
/// This is a receiver capability boundary, not an alternative implementation of the IG validator.
enum FHIRPointProjection {
    private typealias Identity = ValidatedExchangeEvent.Identifier
    private struct Header: Decodable {
        struct Meta: Decodable { let profile: [String] }
        let meta: Meta?
    }

    static func project(validatedBytes bytes: Data, validatorIdentity: String) throws -> ValidatedExchangeEvent {
        do {
            return try extract(bytes, validatorIdentity: validatorIdentity)
        } catch {
            // Model-decoder errors can contain participant values and coding paths.
            throw FHIRValidationClient.invalid
        }
    }

    private static func extract(_ bytes: Data, validatorIdentity: String) throws -> ValidatedExchangeEvent {
        guard !bytes.isEmpty, bytes.count <= FHIRValidationClient.maximumBytes else { throw FHIRValidationClient.invalid }
        // Enforce the receiver's tighter nesting bound and retain number tokens before
        // any model decoder can round them. This is not graph or identity validation.
        let quantities = try ValidatedQuantityLexemes.extract(from: bytes)
        let header = try JSONDecoder().decode(Header.self, from: bytes)
        if let profile = Profile.groveMobileRetractionBundle.value?.url.absoluteString,
           header.meta?.profile.contains(profile) == true {
            return try FHIRRetractionProjection.project(bytes: bytes, validatorIdentity: validatorIdentity)
        }
        // Shared graph/identity rules consume the original bytes; receiver capability and
        // authorization checks remain separate from both this contract and full IG validation.
        let graph = try ExchangeGraph(validating: bytes, kind: .active)
        try FHIRPointSupportBoundary.validateExtensionLocations(in: bytes)
        guard let entries = graph.bundle.entry, (1...512).contains(entries.count) else { throw FHIRValidationClient.invalid }
        let event = graph.event
        let (nodes, resources) = try index(entries)
        try FHIRPointSupportBoundary.validate(resources: resources)
        var participants: Set<Identity> = []
        var outputs: [ValidatedExchangeEvent.PointOutput] = []
        for node in nodes {
            guard let resource = resources[node.fullURL] else { throw FHIRValidationClient.invalid }
            participants.formUnion(try participantIdentifiers(resource, resources: resources))
            if case .observation(let observation) = resource {
                guard let quantity = quantities[node.ordinal] else { throw FHIRValidationClient.invalid }
                outputs.append(try point(observation, fullURL: node.fullURL, quantityText: quantity))
            }
        }
        guard participants.count == 1, !outputs.isEmpty else { throw FHIRValidationClient.invalid }
        var result = ValidatedExchangeEvent(
            rawBytes: bytes,
            validatorIdentity: validatorIdentity,
            eventIdentifierSystem: event.system.rawValue,
            eventIdentifierValue: event.value,
            producerInstance: graph.eventIdentifier.producerInstance,
            participants: participants,
            nodes: nodes,
            outputs: outputs
        )
        _ = try ClinicalRecordRevision(result)
        try FHIRClinicalDerivations.extract(resources: resources, into: &result)
        return result
    }

    private static func index(_ entries: [BundleEntry]) throws -> ([ValidatedExchangeEvent.Node], [String: ResourceProxy]) {
        var resources: [String: ResourceProxy] = [:]
        var nodes: [ValidatedExchangeEvent.Node] = []
        for (ordinal, entry) in entries.enumerated() {
            guard let fullURL = entry.fullUrl?.value?.url.absoluteString, let resource = entry.resource,
                  resources.updateValue(resource, forKey: fullURL) == nil else { throw FHIRValidationClient.invalid }
            if let domain = resource.get() as? any DomainResource {
                guard domain.contained?.isEmpty != false, domain.modifierExtension?.isEmpty != false else {
                    throw FHIRValidationClient.invalid
                }
            }
            nodes.append(.init(ordinal: ordinal, fullURL: fullURL, resourceType: resource.resourceType))
        }
        return (nodes, resources)
    }

    private static func participantIdentifiers(_ resource: ResourceProxy, resources: [String: ResourceProxy]) throws -> [Identity] {
        switch resource {
        case .patient(let patient):
            return [try patientIdentifier(patient)]
        case .observation(let observation):
            return try [subject(observation.subject, resources: resources)]
                + (observation.performer ?? []).map { try subject($0, resources: resources) }
        case .questionnaireResponse(let response):
            return [try subject(response.subject, resources: resources)]
        case .researchSubject(let researchSubject):
            return [try subject(researchSubject.individual, resources: resources)]
        case .device(let device):
            return try device.patient.map { [try subject($0, resources: resources)] } ?? []
        case .provenance, .researchStudy, .planDefinition:
            return []
        default:
            throw FHIRValidationClient.invalid
        }
    }

    private static func point(_ observation: Observation, fullURL: String, quantityText: String) throws -> ValidatedExchangeEvent.PointOutput {
        let identifiers = try (observation.identifier ?? []).map(RoledIdentifier.init)
        guard observation.status.value == .final,
              observation.meta?.profile?.contains(Profile.groveMobileHeartRate) == true,
              let profile = Profile.groveMobileHeartRate.value?.url.absoluteString,
              case .dateTime(let primitive)? = observation.effective, let effective = primitive.value,
              effective.time != nil, effective.timeZone != nil,
              case .quantity(let quantity)? = observation.value, quantity.value?.value != nil, quantity.comparator == nil,
              let quantitySystem = quantity.system?.value?.url.absoluteString, let quantityCode = quantity.code?.value?.string,
              let coding = observation.code.coding?.first, observation.code.coding?.count == 1,
              let codeSystem = coding.system?.value?.url.absoluteString, let code = coding.code?.value?.string,
              observation.component?.isEmpty != false, observation.hasMember?.isEmpty != false,
              observation.focus?.isEmpty != false, observation.specimen == nil,
              observation.basedOn?.isEmpty != false, observation.partOf?.isEmpty != false, observation.encounter == nil else {
            throw FHIRValidationClient.invalid
        }
        let writers = identifiers.filter { $0.role == .writerRecord }
        let versions = (observation.extension ?? []).filter { $0.url == Canonicals.writerRecordVersion }
        guard writers.count <= 1, writers.count == versions.count else { throw FHIRValidationClient.invalid }
        let writerVersion: String?
        if let version = versions.first {
            guard case .string(let raw)? = version.value, let text = raw.value?.string else { throw FHIRValidationClient.invalid }
            writerVersion = text
        } else {
            writerVersion = nil
        }
        return try .init(
            fullURL: fullURL,
            profile: profile,
            effectiveAt: effective.asNSDate(),
            sourceRecordIdentifier: oneIdentifier(identifiers, role: .sourceRecord),
            sourceOutputIdentifier: oneIdentifier(identifiers, role: .sourceOutput),
            writerIdentifier: writers.first.map { .init(system: $0.identifier.system.rawValue, value: $0.identifier.value) },
            writerVersion: writerVersion,
            quantityValue: quantityText,
            quantitySystem: quantitySystem,
            quantityCode: quantityCode,
            codeSystem: codeSystem,
            code: code
        )
    }

    private static func oneIdentifier(_ identifiers: [RoledIdentifier], role: GroveIdentifierRole) throws -> Identity {
        let matches = identifiers.filter { $0.role == role }
        guard matches.count == 1, let match = matches.first else { throw FHIRValidationClient.invalid }
        return .init(system: match.identifier.system.rawValue, value: match.identifier.value)
    }

    private static func identifier(_ identifier: Identifier) throws -> Identity {
        let identifier = try BusinessIdentifier(identifier)
        return .init(system: identifier.system.rawValue, value: identifier.value)
    }

    private static func patientIdentifier(_ patient: Patient) throws -> Identity {
        guard patient.identifier?.count == 1, let first = patient.identifier?.first else { throw FHIRValidationClient.invalid }
        return try identifier(first)
    }

    private static func subject(_ reference: Reference?, resources: [String: ResourceProxy]) throws -> Identity {
        guard let reference else { throw FHIRValidationClient.invalid }
        if let fullURL = reference.reference?.value?.string {
            guard case .patient(let patient)? = resources[fullURL] else { throw FHIRValidationClient.invalid }
            let identity = try patientIdentifier(patient)
            if let explicit = reference.identifier, try identifier(explicit) != identity { throw FHIRValidationClient.invalid }
            return identity
        }
        guard reference.type?.value?.url.absoluteString == "Patient", let logical = reference.identifier else {
            throw FHIRValidationClient.invalid
        }
        return try identifier(logical)
    }
}
