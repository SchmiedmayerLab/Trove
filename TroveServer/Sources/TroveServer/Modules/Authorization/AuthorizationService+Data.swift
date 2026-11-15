//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation


extension AuthorizationService {
    func checkResearcherHasStudyDataAccess(_ id: UUID, actor: AuthContext, on database: any Database) async throws -> Study {
        guard actor.clientAccess == .interactive, actor.roles.contains(actor.researcherRole) else { throw ServerError.forbidden }
        guard let study = try await Study.find(id, on: database) else {
            throw ServerError.notFound(resource: "Study", identifier: id.uuidString)
        }
        try await checkResearcherHasStudyDataAccess(study, actor: actor, on: database)
        return study
    }

    /// Recheck the exact locked study snapshot on the disclosure transaction.
    func checkResearcherHasStudyDataAccess(_ study: Study, actor: AuthContext, on database: any Database) async throws {
        guard let group = try await Group.find(study.$group.id, on: database) else {
            throw ServerError.notFound("Study group not found")
        }
        try actor.checkDataAccess(groupName: group.name)
    }
}
