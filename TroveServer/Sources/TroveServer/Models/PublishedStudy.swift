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

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        studyId: UUID,
        revision: Int,
        visibility: StudyVisibility,
        enrollmentCondition: EnrollmentConditions,
        metadata: StudyDefinition.Metadata,
        id: UUID? = nil
    ) {
        self.id = id
        self.$study.id = studyId
        self.revision = revision
        self.visibility = visibility
        self.enrollmentCondition = enrollmentCondition
        self.metadata = metadata
    }
}
