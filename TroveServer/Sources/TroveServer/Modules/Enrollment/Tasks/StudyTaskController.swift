//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import TroveAPIServer


extension Controller {
    func getStudyTasks(_ input: Operations.GetStudyTasks.Input) async throws -> Operations.GetStudyTasks.Output {
        let page = try await studyService.taskPage(studyID: input.path.studyId.requireId(), after: input.query.after, limit: input.query.limit ?? 50)
        return .ok(.init(headers: .init(cacheControl: .noStore), body: .json(page)))
    }
}
