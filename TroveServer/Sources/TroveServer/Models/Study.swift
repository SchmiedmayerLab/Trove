//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import GroveLocalization
import GroveStudyDefinition
import TroveAPIServer
import Vapor


struct StudyPatch: Sendable {
    var locales: Set<LocalizationKey>? // swiftlint:disable:this discouraged_optional_collection
    var icon: String?
    var details: LocalizationsDictionary<StudyDetailContent>?
    var participationCriterion: StudyDefinition.ParticipationCriterion?
    var consent: LocalizationsDictionary<ConsentContent>?
    var visibility: StudyVisibility?
    var enrollmentCondition: EnrollmentConditions?
    var collectionRequirements: [CollectionRequirement]? // swiftlint:disable:this discouraged_optional_collection
}


final class Study: Model, @unchecked Sendable {
    /// A document wrapper prevents PostgreSQL's driver from treating a Swift array
    /// as a native SQL array rather than the JSON collection configuration.
    private struct CollectionConfiguration: Codable, Sendable {
        var requirements: [CollectionRequirement]
    }

    static let schema = "studies"

    @ID(key: .id) var id: UUID?

    @Parent(key: "group_id") var group: Group

    /// One revision covers the study and all of its components and schedules.
    /// It changes only in the same transaction as an accepted draft mutation.
    @Field(key: "draft_revision") var draftRevision: UUID

    @Field(key: "locales") var locales: Set<LocalizationKey>

    @Field(key: "icon") var icon: String

    @Field(key: "details") var details: LocalizationsDictionary<StudyDetailContent>

    @Field(key: "participation_criterion") var participationCriterion: StudyDefinition.ParticipationCriterion

    @Field(key: "consent") var consent: LocalizationsDictionary<ConsentContent>

    @Field(key: "visibility") var visibility: StudyVisibility

    @Field(key: "enrollment_condition") var enrollmentCondition: EnrollmentConditions

    @Field(key: "collection_configuration") private var collectionConfiguration: CollectionConfiguration

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    @Children(for: \.$study) var components: [Component]

    @Children(for: \.$study) var publishedStudies: [PublishedStudy]

    @Children(for: \.$study) var enrollments: [Enrollment]

    @Children(for: \.$study) var invitationCodes: [InvitationCode]

    var collectionRequirements: [CollectionRequirement] {
        get { collectionConfiguration.requirements }
        set { collectionConfiguration = .init(requirements: newValue) }
    }

    init() {}

    init(
        groupId: UUID,
        locales: Set<LocalizationKey>,
        icon: String,
        details: LocalizationsDictionary<StudyDetailContent> = .init(),
        participationCriterion: StudyDefinition.ParticipationCriterion = .all([]),
        consent: LocalizationsDictionary<ConsentContent> = .init(),
        visibility: StudyVisibility = .public,
        enrollmentCondition: EnrollmentConditions = .none,
        collectionRequirements: [CollectionRequirement] = [],
        id: UUID? = nil
    ) {
        self.id = id
        self.$group.id = groupId
        self.draftRevision = UUID()
        self.locales = locales
        self.icon = icon
        self.details = details
        self.participationCriterion = participationCriterion
        self.consent = consent
        self.visibility = visibility
        self.enrollmentCondition = enrollmentCondition
        self.collectionRequirements = collectionRequirements
    }

    func requireDraftRevision(_ expectedRevision: UUID) throws {
        guard draftRevision == expectedRevision else {
            throw ServerError.preconditionFailed("The study draft changed; reload it before applying this operation")
        }
    }

    func apply(_ patch: StudyPatch) throws {
        if let requirements = patch.collectionRequirements {
            try CollectionRequirement.validate(requirements)
        }
        func apply<T>(_ otherKeyPath: KeyPath<StudyPatch, T?>, to selfKeyPath: ReferenceWritableKeyPath<Study, T>) {
            if let value = patch[keyPath: otherKeyPath] {
                self[keyPath: selfKeyPath] = value
            }
        }

        apply(\.locales, to: \.locales)
        apply(\.icon, to: \.icon)
        apply(\.details, to: \.details)
        apply(\.participationCriterion, to: \.participationCriterion)
        apply(\.consent, to: \.consent)
        apply(\.visibility, to: \.visibility)
        apply(\.enrollmentCondition, to: \.enrollmentCondition)
        apply(\.collectionRequirements, to: \.collectionRequirements)
    }
}
