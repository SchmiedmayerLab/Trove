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


final class PublishedStudy: Model, @unchecked Sendable {
    static let schema = "published_studies"

    @ID(key: .id) var id: UUID?

    @Parent(key: "study_id") var study: Study

    @Field(key: "revision") var revision: Int

    @Field(key: "visibility") var visibility: StudyVisibility

    @Field(key: "enrollment_condition") var enrollmentCondition: EnrollmentConditions

    @Field(key: "metadata") var metadata: StudyDefinition.Metadata

    @Field(key: "bundle_key") var bundleKey: String

    @Field(key: "bundle_digest") var bundleDigest: String

    @Field(key: "task_plan") var taskPlan: PublishedTaskPlan

    @Field(key: "artifact_id") var artifactID: UUID

    /// Exact localized Markdown included in the archive, never regenerated from an editable draft.
    @Field(key: "consent_snapshot") var consentSnapshot: LocalizationsDictionary<String>

    @Field(key: "collection_policy") var collectionPolicy: PublishedCollectionPolicy

    @Field(key: "definition_schema_version") var definitionSchemaVersion: String

    @Field(key: "contract_version") var contractVersion: String

    @Field(key: "contract_revision") var contractRevision: String

    @Field(key: "validator_identity") var validatorIdentity: String

    @Field(key: "execution_capability") var executionCapability: String

    @Field(key: "instruments") private var instrumentDocument: PublicationEvidence.Instruments

    /// Readiness facts the revision was validated with. They are not part of the participant bundle.
    @Field(key: "readiness_facts") var readinessFacts: StudyReadinessFacts

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    var instruments: [PublishedInstrument] {
        instrumentDocument.instruments
    }

    init() {}

    init(
        studyId: UUID,
        revision: Int,
        visibility: StudyVisibility,
        enrollmentCondition: EnrollmentConditions,
        metadata: StudyDefinition.Metadata,
        bundleKey: String,
        bundleDigest: String,
        artifactID: UUID,
        consentSnapshot: LocalizationsDictionary<String>,
        collectionPolicy: PublishedCollectionPolicy,
        taskPlan: PublishedTaskPlan,
        evidence: PublicationEvidence,
        id: UUID? = nil
    ) {
        self.id = id
        self.$study.id = studyId
        self.revision = revision
        self.visibility = visibility
        self.enrollmentCondition = enrollmentCondition
        self.metadata = metadata
        self.bundleKey = bundleKey
        self.bundleDigest = bundleDigest
        self.artifactID = artifactID
        self.consentSnapshot = consentSnapshot
        self.taskPlan = taskPlan
        self.collectionPolicy = collectionPolicy
        self.definitionSchemaVersion = evidence.definitionSchemaVersion
        self.contractVersion = evidence.contractVersion
        self.contractRevision = evidence.contractRevision
        self.validatorIdentity = evidence.validatorIdentity
        self.executionCapability = evidence.executionCapability
        self.instrumentDocument = .init(instruments: evidence.instruments)
        self.readinessFacts = evidence.readinessFacts
    }
}
