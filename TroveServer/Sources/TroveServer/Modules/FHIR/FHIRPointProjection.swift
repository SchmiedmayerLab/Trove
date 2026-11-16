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


/// Extracts supported immutable clinical outputs only AFTER complete validation of the exact bytes.
/// This is a receiver capability boundary, not an alternative implementation of the IG validator.
enum FHIRPointProjection {
    private typealias Identity = ValidatedExchangeEvent.Identifier
    private struct ClinicalOutputs {
        let participants: Set<Identity>
        let outputs: [ValidatedExchangeEvent.Output]
        let nativeIdentifiers: [Identity]
        let syncIdentifiers: [Identity]
    }

    private struct Header: Decodable {
        struct Meta: Decodable { let profile: [String] }
        let meta: Meta?
    }

    static func project(
        validatedBytes bytes: Data, validatorIdentity: String, recordings: [ClinicalRecordingAttachment] = []
    ) throws -> ValidatedExchangeEvent {
        do {
            return try extract(bytes, validatorIdentity: validatorIdentity, recordings: recordings)
        } catch {
            // Model-decoder errors can contain participant values and coding paths.
            throw FHIRValidationClient.invalid
        }
    }

    private static func extract(
        _ bytes: Data, validatorIdentity: String, recordings: [ClinicalRecordingAttachment]
    ) throws -> ValidatedExchangeEvent {
        guard !bytes.isEmpty, bytes.count <= FHIRValidationClient.maximumBytes else { throw FHIRValidationClient.invalid }
        // Enforce the receiver's tighter nesting bound and retain number tokens before
        // any model decoder can round them. This is not graph or identity validation.
        let quantities = try ValidatedQuantityLexemes.extract(from: bytes)
        let header = try JSONDecoder().decode(Header.self, from: bytes)
        if let profile = Profile.groveMobileRetractionBundle.value?.url.absoluteString,
           header.meta?.profile.contains(profile) == true {
            guard recordings.isEmpty else { throw FHIRValidationClient.invalid }
            return try FHIRRetractionProjection.project(bytes: bytes, validatorIdentity: validatorIdentity)
        }
        // Shared graph/identity rules consume the original bytes; receiver capability and
        // authorization checks remain separate from both this contract and full IG validation.
        let graph = try ExchangeGraph(validating: bytes, kind: .active)
        try FHIRPointSupportBoundary.validateExtensionLocations(in: bytes)
        guard let entries = graph.bundle.entry, (1...512).contains(entries.count) else { throw FHIRValidationClient.invalid }
        let record = try ExchangeRecord(validating: bytes)
        let (nodes, resources) = try index(entries)
        try FHIRPointSupportBoundary.validate(resources: resources)
        try FHIRWorkoutProjection.validate(resources: resources)
        try FHIRHealthKitECGBoundary.validate(resources: resources)
        try FHIRRecordingSourcePeriod.validate(resources: resources)
        let clinical = try clinicalOutputs(nodes, resources: resources, quantities: quantities, recordings: recordings)
        try validateOutputs(
            clinical.outputs, participants: clinical.participants, nativeIdentifiers: clinical.nativeIdentifiers, recordings: recordings
        )
        let deploymentIdentifiers = try JSONDecoder().decode(FHIRDeploymentIdentifiers.self, from: bytes)
        // One readable sync identifier at most, only where a primary admitted it, never under a Grove identity system.
        let identitySystems = deploymentIdentifiers.systems.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        guard clinical.syncIdentifiers.count <= 1, try FHIRSyncRecordIdentifier.count(in: bytes) == clinical.syncIdentifiers.count,
              clinical.syncIdentifiers.allSatisfy({ !identitySystems.contains($0.system) }) else { throw FHIRValidationClient.invalid }
        var result = ValidatedExchangeEvent(
            rawBytes: bytes,
            recorded: try RecordedInstant.extract(from: resources),
            validatorIdentity: validatorIdentity,
            eventIdentifierSystem: record.version.identifier.identifier.system.rawValue,
            eventIdentifierValue: record.version.identifier.identifier.value,
            deploymentIdentifiers: deploymentIdentifiers,
            participants: clinical.participants,
            nodes: nodes,
            outputs: clinical.outputs,
            nativeRecordIdentifiers: clinical.nativeIdentifiers,
            syncRecordIdentifiers: clinical.syncIdentifiers,
            recordings: recordings
        )
        _ = try ClinicalRecordRevision(result)
        try FHIRClinicalDerivations.extract(resources: resources, into: &result)
        try FHIRSensorKitCompanions.validateDependencies(result)
        return result
    }

    private static func clinicalOutputs(
        _ nodes: [ValidatedExchangeEvent.Node],
        resources: [String: ResourceProxy],
        quantities: [Int: String],
        recordings: [ClinicalRecordingAttachment]
    ) throws -> ClinicalOutputs {
        var participants: Set<Identity> = []
        var outputs: [ValidatedExchangeEvent.Output] = []
        var nativeIdentifiers: [ValidatedExchangeEvent.Identifier] = []
        var syncIdentifiers: [ValidatedExchangeEvent.Identifier] = []
        for node in nodes {
            guard let resource = resources[node.fullURL] else { throw FHIRValidationClient.invalid }
            participants.formUnion(try participantIdentifiers(resource, resources: resources))
            if case .observation(let observation) = resource {
                let identifiers = try FHIRNativeRecordIdentifiers.output(observation.identifier ?? [], extensions: observation.extension ?? [])
                nativeIdentifiers.append(contentsOf: identifiers.native)
                syncIdentifiers.append(contentsOf: identifiers.sync)
                outputs.append(try output(
                    observation, identifiers: identifiers.roles, fullURL: node.fullURL, quantityText: quantities[node.ordinal]
                ))
            } else if case .documentReference(let document) = resource {
                let identifiers = try FHIRNativeRecordIdentifiers.output(document.identifier ?? [], extensions: document.extension ?? [])
                nativeIdentifiers.append(contentsOf: identifiers.native)
                syncIdentifiers.append(contentsOf: identifiers.sync)
                outputs.append(try recording(
                    document, identifiers: identifiers.roles, fullURL: node.fullURL, recordings: recordings, resources: resources
                ))
            }
        }
        return .init(participants: participants, outputs: outputs, nativeIdentifiers: nativeIdentifiers, syncIdentifiers: syncIdentifiers)
    }

    private static func validateOutputs(
        _ outputs: [ValidatedExchangeEvent.Output],
        participants: Set<Identity>,
        nativeIdentifiers: [Identity],
        recordings: [ClinicalRecordingAttachment]
    ) throws {
        guard participants.count == 1, !outputs.isEmpty, nativeIdentifiers.count <= 1,
              Set(recordings.map { $0.declaration.output.fullURL }).count == recordings.count,
              recordings.allSatisfy({ attachment in
                  outputs.contains { $0.fullURL == attachment.declaration.output.fullURL && $0.value == .recording }
              }) else { throw FHIRValidationClient.invalid }
        try FHIRSensorKitCompanions.validate(outputs)
    }

    static func index(_ entries: [BundleEntry]) throws -> ([ValidatedExchangeEvent.Node], [String: ResourceProxy]) {
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
        case .documentReference(let document):
            return [try subject(document.subject, resources: resources)]
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

    private static func output(
        _ observation: Observation, identifiers: [RoledIdentifier], fullURL: String, quantityText: String?
    ) throws -> ValidatedExchangeEvent.Output {
        let value = try FHIRObservationValueProjection(observation: observation, quantityText: quantityText)
        let sourceType = try FHIRSourceTypeEvidence.extract(observation.extension ?? [])
        let writer = try writerRevision(identifiers: identifiers, extensions: observation.extension ?? [])
        return try .init(
            fullURL: fullURL,
            profile: value.profile,
            measurementBounds: value.measurementBounds,
            sourceRecordIdentifier: oneIdentifier(identifiers, role: .sourceRecord),
            sourceOutputIdentifier: oneIdentifier(identifiers, role: .sourceOutput),
            writerIdentifier: writer.identifier,
            writerVersion: writer.version,
            value: value.value,
            codeSystem: value.codeSystem,
            code: value.code,
            sourceTypeIdentifier: sourceType?.identifier,
            sourceRepositoryKind: sourceType?.repository
        )
    }

    private static func recording(
        _ document: DocumentReference,
        identifiers: [RoledIdentifier],
        fullURL: String,
        recordings: [ClinicalRecordingAttachment],
        resources: [String: ResourceProxy]
    ) throws -> ValidatedExchangeEvent.Output {
        let external = recordings.first { $0.declaration.output.fullURL == fullURL }
        let period = try FHIRRecordingSourcePeriod.period(document, fullURL: fullURL, resources: resources)
        let facts = try FHIRRecordingProjection.project(document, external: external, selectionPeriod: period)
        // The exact source-artifact identity remains in the immutable document and study view.
        _ = try oneIdentifier(identifiers, role: .sourceArtifact)
        // A recording record's sole document is its primary output and states the writer revision like an Observation.
        let writer = try writerRevision(identifiers: identifiers, extensions: document.extension ?? [])
        return try .init(
            fullURL: fullURL,
            profile: facts.profile,
            measurementBounds: facts.bounds,
            sourceRecordIdentifier: oneIdentifier(identifiers, role: .sourceRecord),
            sourceOutputIdentifier: oneIdentifier(identifiers, role: .sourceOutput),
            writerIdentifier: writer.identifier,
            writerVersion: writer.version,
            value: .recording,
            codeSystem: FHIRRecordingProjection.formatSystem,
            code: facts.format.rawValue,
            sourceTypeIdentifier: facts.source.identifier,
            sourceRepositoryKind: facts.source.repository,
            rowExtent: facts.rows
        )
    }

    /// The writer-record identity and its version travel as one complete pair or not at all; ``ClinicalRecordRevision``
    /// checks the canonical version text and that every output of the record states the same pair.
    private static func writerRevision(
        identifiers: [RoledIdentifier], extensions: [Extension]
    ) throws -> (identifier: Identity?, version: String?) {
        let writers = identifiers.filter { $0.role == .writerRecord }
        let versions = extensions.filter { $0.url == Canonicals.writerRecordVersion }
        guard writers.count <= 1, writers.count == versions.count else { throw FHIRValidationClient.invalid }
        guard let writer = writers.first, let version = versions.first else {
            return (nil, nil)
        }
        guard case .string(let raw)? = version.value, let text = raw.value?.string else { throw FHIRValidationClient.invalid }
        return (.init(system: writer.identifier.system.rawValue, value: writer.identifier.value), text)
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
        // A context snapshot identifies this representation of the Patient, not the participant.
        let identifiers = (patient.identifier ?? []).filter { (try? RoledIdentifier($0))?.role != .contextSnapshot }
        guard identifiers.count == 1, let first = identifiers.first else { throw FHIRValidationClient.invalid }
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
