//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Spezi
import SpeziFoundation


final class GroupService: Module, @unchecked Sendable {
    @Dependency(GroupRepository.self) var repository
    @Dependency(AuthorizationService.self) var authorizationService

    func listGroups() async throws -> [Group] {
        let context = try authorizationService.checkIsResearcher()
        let accessibleNames = Array(context.groupMemberships.keys)
        return try await repository.findByNames(accessibleNames)
    }

    func getGroup(id: UUID) async throws -> Group {
        try await authorizationService.checkResearcherHasGroupAccess(id, role: .researcher)
    }

    /// Creates local groups for any Keycloak top-level groups not yet in the database.
    /// Groups removed from Keycloak are kept locally to preserve associated studies.
    func syncGroups(from keycloakGroups: [KeycloakGroup]) async throws {
        let existingNames = try await repository.listAll().mapIntoSet(\.name)

        for keycloakGroup in keycloakGroups where !existingNames.contains(keycloakGroup.name) {
            try await repository.create(Group(name: keycloakGroup.name, icon: "tree-pine"))
        }
    }
}
