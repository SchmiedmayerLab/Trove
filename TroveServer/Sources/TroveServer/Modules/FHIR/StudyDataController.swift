//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import TroveAPIServer


extension Controller {
    func getStudyData(_ input: Operations.GetStudyData.Input) async throws -> Operations.GetStudyData.Output {
        do {
            let page = try await studyService.dataPage(
                studyID: input.path.studyId.requireId(),
                versions: input.query.versions == .history ? .history : .current,
                before: input.query.before.map { try $0.requireId() },
                limit: input.query.limit ?? 20
            )
            return .ok(.init(headers: .init(cacheControl: .noStore), body: .json(page)))
        } catch StudyProjectionJSON.Failure.outputTooLarge {
            // Only this closed, payload-free failure produces actionable capacity detail.
            // Other server failures continue through the ordinary sanitized error middleware.
            return .default(statusCode: 503, .init(body: .applicationProblemJson(.init(
                title: "Study Data Capacity Exceeded",
                status: 503,
                detail: "Study data exceeds the response limit; request fewer outputs"
            ))))
        }
    }
}
