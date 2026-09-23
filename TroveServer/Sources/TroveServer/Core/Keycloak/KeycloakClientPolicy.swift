//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import TroveAPIServer


/// Deployment-owned registration policy. A caller cannot select its access mode.
struct KeycloakClientPolicy: Sendable {
    enum Access: Sendable {
        case interactive
        case delegatedDraft
    }

    static let production = Self(clients: [
        "trove-web": .interactive, "trove-app": .interactive, "trove-cli": .interactive, "trove-draft-editor": .delegatedDraft
    ])
    static let development = Self(clients: production.clients.merging(["trove-dev-cli": .interactive]) { current, _ in current })

    let clients: [String: Access]

    /// Deny by default, including new operations and tokens carrying unrelated roles.
    static func draftPermission(for operationID: String) -> DraftPermission? {
        switch operationID {
        case Operations.GetStudiesStudyId.id, Operations.GetStudiesStudyIdComponents.id,
             Operations.GetStudiesStudyIdComponentsInformationalComponentId.id,
             Operations.GetStudiesStudyIdComponentsQuestionnaireComponentId.id,
             Operations.GetStudiesStudyIdComponentsHealthDataComponentId.id,
             Operations.GetStudiesStudyIdComponentsComponentIdSchedules.id,
             Operations.GetStudiesStudyIdComponentsComponentIdSchedulesScheduleId.id:
            .inspect
        case Operations.PatchStudiesStudyId.id, Operations.DeleteStudiesStudyIdComponentsComponentId.id,
             Operations.PostStudiesStudyIdComponentsInformational.id, Operations.PutStudiesStudyIdComponentsInformationalComponentId.id,
             Operations.PostStudiesStudyIdComponentsQuestionnaire.id, Operations.PutStudiesStudyIdComponentsQuestionnaireComponentId.id,
             Operations.PostStudiesStudyIdComponentsHealthData.id, Operations.PutStudiesStudyIdComponentsHealthDataComponentId.id,
             Operations.PostStudiesStudyIdComponentsComponentIdSchedules.id,
             Operations.PutStudiesStudyIdComponentsComponentIdSchedulesScheduleId.id,
             Operations.DeleteStudiesStudyIdComponentsComponentIdSchedulesScheduleId.id:
            .edit
        case "validateStudyDraft": .validate
        default: nil
        }
    }

    func access(for clientID: String) throws -> Access {
        guard let access = clients[clientID] else { throw ServerError.invalidToken }
        return access
    }

    func permitsDelegation(to clientID: String) -> Bool {
        clients[clientID] == .delegatedDraft
    }
}
