//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import OpenAPIRuntime
import TroveAPIServer


extension Controller {
    func getStudiesStudyId(_ input: Operations.GetStudiesStudyId.Input) async throws -> Operations.GetStudiesStudyId.Output {
        let studyId = try input.path.studyId.requireId()
        let study = try await studyService.getStudy(id: studyId)
        return .ok(.init(body: .json(try .init(study))))
    }

    func postGroupsGroupIdStudies(
        _ input: Operations.PostGroupsGroupIdStudies.Input
    ) async throws -> Operations.PostGroupsGroupIdStudies.Output {
        guard case .json(let schema) = input.body else {
            throw ServerError.jsonBodyRequired
        }

        let groupId = try input.path.groupId.requireId()
        let study = try await studyService.createStudy(groupId: groupId, study: Study(schema, groupId: groupId))
        return .created(.init(body: .json(try .init(study))))
    }

    func getGroupsGroupIdStudies(
        _ input: Operations.GetGroupsGroupIdStudies.Input
    ) async throws -> Operations.GetGroupsGroupIdStudies.Output {
        let groupId = try input.path.groupId.requireId()
        let studies = try await studyService.listStudies(groupId: groupId)
        return .ok(.init(body: .json(try studies.map { try .init($0) })))
    }

    func patchStudiesStudyId(_ input: Operations.PatchStudiesStudyId.Input) async throws -> Operations.PatchStudiesStudyId.Output {
        guard case .json(let schema) = input.body else {
            throw ServerError.jsonBodyRequired
        }

        let studyId = try input.path.studyId.requireId()
        let study = try await studyService.patchStudy(id: studyId, patch: StudyPatch(schema))
        return .ok(.init(body: .json(try .init(study))))
    }

    func deleteStudiesStudyId(_ input: Operations.DeleteStudiesStudyId.Input) async throws -> Operations.DeleteStudiesStudyId.Output {
        let studyId = try input.path.studyId.requireId()
        try await studyService.deleteStudy(id: studyId)
        return .noContent(.init())
    }
}
