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


/// Immutable validation evidence. Its ID is also the future publication's retry identity.
/// Fluent instances are confined to one request/transaction; no shared mutable model is retained.
final class StudyPublicationCandidate: Model, @unchecked Sendable {
    struct QuestionnaireEvidence: Codable, Sendable {
        let componentID: UUID
        let locale: String
        let validation: QuestionnaireValidationService.Evidence
    }

    struct Snapshot: Codable, Sendable {
        let metadata: StudyDefinition.Metadata
        let consent: LocalizationsDictionary<String>
        let visibility: StudyVisibility
        let enrollmentCondition: EnrollmentConditions
        let collectionPolicy: PublishedCollectionPolicy
        let questionnaires: [QuestionnaireEvidence]
    }

    static let schema = "study_publication_candidates"

    @ID(key: .id) var id: UUID?
    @Field(key: "study_id") var studyID: UUID
    @Field(key: "group_id") var groupID: UUID
    @Field(key: "draft_revision") var draftRevision: UUID
    @Field(key: "publication_revision") var publicationRevision: Int
    @Field(key: "artifact_id") var artifactID: UUID
    @Field(key: "bundle_digest") var bundleDigest: String
    @Field(key: "byte_count") var byteCount: Int
    @Field(key: "validator_identity") var validatorIdentity: String
    @Field(key: "contract_revision") var contractRevision: String
    @Field(key: "execution_capability") var executionCapability: String
    @Field(key: "snapshot") var snapshot: Snapshot
    @Field(key: "created_at") var createdAt: Date
    @Field(key: "expires_at") var expiresAt: Date

    var artifact: ArtifactReference {
        .init(id: artifactID, ownerID: studyID, purpose: .publication, digest: bundleDigest, byteCount: byteCount)
    }

    init() {}

    init(
        studyID: UUID,
        groupID: UUID,
        draftRevision: UUID,
        publicationRevision: Int,
        artifact: ArtifactReference,
        validatorIdentity: String,
        snapshot: Snapshot,
        createdAt: Date,
        expiresAt: Date
    ) {
        self.id = UUID()
        self.studyID = studyID
        self.groupID = groupID
        self.draftRevision = draftRevision
        self.publicationRevision = publicationRevision
        self.artifactID = artifact.id
        self.bundleDigest = artifact.digest
        self.byteCount = artifact.byteCount
        self.validatorIdentity = validatorIdentity
        self.contractRevision = FHIRValidationClient.contractRevision
        self.executionCapability = QuestionnaireValidationService.executionCapability
        self.snapshot = snapshot
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    func requireCurrentEvidence(validatorIdentity: String?, now: Date) throws {
        guard createdAt <= now, expiresAt > now,
              self.validatorIdentity == validatorIdentity,
              contractRevision == FHIRValidationClient.contractRevision,
              executionCapability == QuestionnaireValidationService.executionCapability else {
            throw ServerError.conflict("Validation is no longer current; validate the study draft again")
        }
    }
}
