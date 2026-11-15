//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SQLKit


/// Recording custody belongs to a participant's source; study grants are independent of storage ownership.
struct ParticipantArtifactScope: Sendable, Equatable {
    let participantID: UUID
    let sourceBindingID: UUID
}


enum ArtifactScope: Sendable, Equatable {
    case study(StudyArtifactScope)
    case participantSource(ParticipantArtifactScope)

    var auditScope: AuditEvent.Scope {
        switch self {
        case .study(let scope): .study(studyID: scope.studyID, groupID: scope.groupID)
        case .participantSource(let scope): .participantSource(participantID: scope.participantID, sourceBindingID: scope.sourceBindingID)
        }
    }

    var discardAction: AuditEvent.Action {
        switch self {
        case .study: .artifactDiscardScheduled
        case .participantSource: .recordingArtifactDiscardScheduled
        }
    }

    var matchingColumns: SQLQueryString {
        switch self {
        case .study(let scope):
            let group: SQLQueryString = scope.groupID.map { "group_id = \(bind: $0)" } ?? "group_id IS NULL"
            return "study_id = \(bind: scope.studyID) AND \(group) AND participant_id IS NULL AND source_binding_id IS NULL"
        case .participantSource(let scope):
            return """
                participant_id = \(bind: scope.participantID) AND source_binding_id = \(bind: scope.sourceBindingID)
                AND study_id IS NULL AND group_id IS NULL
                """
        }
    }
}
