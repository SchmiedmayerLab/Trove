// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import TroveAPITypes
@testable import TroveServer


struct ClinicalDocumentCollectionPolicyTests {
    private let acceptedAt = Date(timeIntervalSinceReferenceDate: 100)

    private func requirement(_ basis: CollectionTimeBasis) throws -> CollectionRequirement {
        let values = try NativeCollectionCapabilities.values().filter { $0.timeBasis == basis }
        let value = try #require(values.first)
        return CollectionRequirement(
            profile: value.profile, sourceKind: .participantApp, sourceTypeIdentifier: value.sourceTypeIdentifier, timeBasis: basis
        )
    }

    @Test(arguments: [CollectionTimeBasis.clinicalRecordDownload, .cdaSourceDocumentPeriod])
    func acceptedDocumentBasisSurvivesArchiveAndCannotBeReconstructedFromMeasurementAuthority(basis: CollectionTimeBasis) throws {
        let requirement = try requirement(basis)
        let studyID = UUID()
        let policy = try PublishedCollectionPolicy.compile(studyID: studyID, revision: 1, requirements: [requirement])
        let scope = try AcceptedCollectionScope(requirements: [requirement], acceptedAt: acceptedAt)
        let retained = try JSONDecoder().decode(AcceptedCollectionScope.self, from: JSONEncoder().encode(scope))
        #expect(retained.requirements.first?.timeBasis == basis)
        #expect(String(decoding: try policy.archiveBytes(), as: UTF8.self).contains(basis.rawValue))
        #expect(try CollectionRequirement(Components.Schemas.CollectionRequirement(requirement)) == requirement)
        let resolved = try policy.resolvedRequirements(studyID: studyID, revision: 1, acceptedAt: acceptedAt, scope: retained, adoptionEnd: nil)
        #expect(resolved.first?.timeBasis == basis)
        for actualBasis in [basis, .measurementTime] {
            #expect(policy.permits(
                studyID: studyID,
                revision: 1,
                profile: requirement.profile,
                sourceKind: .participantApp,
                effectiveAt: acceptedAt,
                consentAcceptedAt: acceptedAt,
                effectiveEnd: acceptedAt,
                scope: retained,
                sourceTypeIdentifier: requirement.sourceTypeIdentifier,
                timeBasis: actualBasis
            ) == (actualBasis == basis))
        }
        for actualBasis in [CollectionTimeBasis?.none, .measurementTime] {
            #expect(throws: ServerError.self) {
                let invalid = CollectionRequirement(
                    profile: requirement.profile,
                    sourceKind: .participantApp,
                    sourceTypeIdentifier: requirement.sourceTypeIdentifier,
                    timeBasis: actualBasis
                )
                try CollectionRequirement.validate([invalid])
            }
        }
    }

    @Test(arguments: ["en", "de"])
    func retainedConsentExplainsWholeDocumentsAndTheirActualSourceDateMeaning(locale: String) throws {
        let clinical = try CollectionScopePresentation.markdown(requirements: [requirement(.clinicalRecordDownload)], locale: locale)
        let cda = try CollectionScopePresentation.markdown(requirements: [requirement(.cdaSourceDocumentPeriod)], locale: locale)
        #expect(clinical.contains(locale == "de" ? "heruntergeladen" : "downloaded"))
        #expect(clinical.contains(locale == "de" ? "vollständige Originaldokument" : "complete original document"))
        #expect(cda.contains(locale == "de" ? "vom Ersteller" : "assigned by the creator"))
        #expect(cda.contains(locale == "de" ? "Dokumentfreigabe" : "document authorization"))
    }
}
