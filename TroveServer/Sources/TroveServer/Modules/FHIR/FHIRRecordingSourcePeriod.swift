//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import GroveFHIRContract
import ModelsR4
import TroveAPITypes


/// Resolves a recording's collection clock from its actual source and bound source Provenance.
enum FHIRRecordingSourcePeriod {
    static func period(
        _ document: DocumentReference, fullURL: String, resources: [String: ResourceProxy]
    ) throws -> Period? {
        let basis = try requiredBasis(document)
        guard basis != .measurementTime else {
            return try FHIRSensorKitCompanions.relatedPeriod(document, fullURL: fullURL, resources: resources)
        }
        let conversions = resources.values.compactMap { resource -> Provenance? in
            guard case .provenance(let provenance) = resource,
                  provenance.meta?.profile?.contains(Profile.healthkitConversionProvenance) == true,
                  provenance.target.contains(where: { $0.reference?.value?.string == fullURL }) else { return nil }
            return provenance
        }
        guard conversions.count == 1, let conversion = conversions.first else { throw FHIRValidationClient.invalid }
        let entities = conversion.entity ?? []
        let sources = entities.filter { $0.role.value == .source }
        guard sources.count == 1, let source = sources.first, let identifier = source.what.identifier else { throw FHIRValidationClient.invalid }
        let sourceIdentity = try RoledIdentifier(identifier)
        let outputs = try FHIRNativeRecordIdentifiers.output(document.identifier ?? []).roles.filter { $0.role == .sourceRecord }
        guard sourceIdentity.role == .sourceRecord, outputs.count == 1,
              outputs.first?.identifier == sourceIdentity.identifier else { throw FHIRValidationClient.invalid }
        return try HealthKitDocumentSelectionTime(entities: entities, expectedBasis: basis).period
    }

    /// A source-document clock is not accepted as an unrelated annotation on another kind of output.
    static func validate(resources: [String: ResourceProxy]) throws {
        for resource in resources.values {
            guard case .provenance(let provenance) = resource,
                  (provenance.entity ?? []).contains(where: { entity in
                      entity.extension?.contains { $0.url == HealthKitSourceDocumentTime.extensionURL } == true
                  }) else { continue }
            guard provenance.target.count == 1, let address = provenance.target.first?.reference?.value?.string,
                  case .documentReference(let document)? = resources[address],
                  try requiredBasis(document) != .measurementTime,
                  try period(document, fullURL: address, resources: resources) != nil else { throw FHIRValidationClient.invalid }
        }
    }

    private static func requiredBasis(_ document: DocumentReference) throws -> CollectionTimeBasis {
        guard let source = try FHIRSourceTypeEvidence.extract(document.extension ?? []), source.repository == .healthKit else {
            return .measurementTime
        }
        let profile = document.meta?.profile?.contains(Profile.healthkitClinicalRecordDocument) == true
            ? Profile.healthkitClinicalRecordDocument : Profile.healthkitRecordingDocument
        guard let canonical = profile.value?.url.absoluteString else { throw FHIRValidationClient.invalid }
        return CollectionTimeBasis.required(profile: canonical, sourceTypeIdentifier: source.identifier)
    }
}
