//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import GroveLocalization
import GroveStudyDefinition
import TroveAPIServer
@testable import TroveServer


enum PublishedStudyFixtures {
    static let requiredConsentMarkdown = "<toggle id=\"agree\" expected-value=\"true\">I agree.</toggle>"

    @discardableResult
    static func createPublishedStudy(
        on database: any Database,
        studyId: UUID,
        revision: Int = 1,
        visibility: StudyVisibility = .public,
        enrollmentCondition: EnrollmentConditions = .none,
        title: String = "Test Study",
        icon: String = "heart",
        consentSnapshot: LocalizationsDictionary<String> = .init([.enUS: requiredConsentMarkdown]),
        participationCriterion: StudyDefinition.ParticipationCriterion = .all([]),
        artifact: ArtifactReference? = nil,
        collectionRequirements: [CollectionRequirement] = [],
        save: Bool = true
    ) async throws -> PublishedStudy {
        let metadata = StudyDefinition.Metadata(
            id: studyId,
            title: .init([.enUS: title]),
            icon: .systemSymbol(icon),
            explanationText: .init([.enUS: ""]),
            shortExplanationText: .init([.enUS: ""]),
            participationCriterion: participationCriterion
        )
        let retainedArtifact: ArtifactReference
        if let artifact {
            retainedArtifact = artifact
        } else {
            retainedArtifact = try await RetainedRecordFixtures.artifact(on: database, ownerID: studyId, studyID: studyId, purpose: .publication)
        }
        let published = PublishedStudy(
            studyId: studyId,
            revision: revision,
            visibility: visibility,
            enrollmentCondition: enrollmentCondition,
            metadata: metadata,
            bundleKey: retainedArtifact.key,
            bundleDigest: retainedArtifact.digest,
            artifactID: retainedArtifact.id,
            consentSnapshot: consentSnapshot,
            collectionPolicy: try .compile(studyID: studyId, revision: revision, requirements: collectionRequirements)
        )
        if save {
            try await published.save(on: database)
        }
        return published
    }
}
