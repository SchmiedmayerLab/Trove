//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPIServer


extension Controller {
    func getGroups(
        _ input: Operations.GetGroups.Input
    ) async throws -> Operations.GetGroups.Output {
        let groups = try await groupService.listGroups()
        return .ok(.init(body: .json(try groups.map { try .init($0) })))
    }

    func getGroupsGroupId(
        _ input: Operations.GetGroupsGroupId.Input
    ) async throws -> Operations.GetGroupsGroupId.Output {
        let groupId = try input.path.groupId.requireId()
        let group = try await groupService.getGroup(id: groupId)
        return .ok(.init(body: .json(try .init(group))))
    }
}
