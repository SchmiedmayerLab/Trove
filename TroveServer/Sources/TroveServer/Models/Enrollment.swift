//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation


/// Placeholder for enrollment-specific data stored as JSON.
struct ParticipationData: Codable, Sendable, Hashable {
    init() {}
}


final class Enrollment: Model, @unchecked Sendable {
    static let schema = "enrollments"

    @ID(key: .id) var id: UUID?

    @Parent(key: "participant_id") var participant: Participant

    @Parent(key: "study_id") var study: Study

    @OptionalParent(key: "invitation_code_id") var invitationCode: InvitationCode?

    @Field(key: "current_revision") var currentRevision: Int

    /// Monotonic concurrency token, initialized to 1 for a new enrollment.
    @Field(key: "state_version") var stateVersion: Int64

    @Field(key: "participation_data") var participationData: ParticipationData
    
    @OptionalField(key: "withdrawn_at") var withdrawnAt: Date?
    
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    @Children(for: \.$enrollment) var consents: [EnrollmentConsent]

    init() {}

    init(
        participantId: UUID,
        studyId: UUID,
        currentRevision: Int,
        invitationCodeId: UUID? = nil,
        participationData: ParticipationData = ParticipationData(),
        id: UUID? = nil
    ) {
        self.id = id
        self.$participant.id = participantId
        self.$study.id = studyId
        self.$invitationCode.id = invitationCodeId
        self.currentRevision = currentRevision
        self.stateVersion = 1
        self.participationData = participationData
    }
}
