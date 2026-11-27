// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import TroveAPIServer


extension Controller {
    func startTaskSession(_ input: Operations.StartTaskSession.Input) async throws -> Operations.StartTaskSession.Output {
        _ = try AuthContext.checkIsParticipant()
        guard case .json(let start) = input.body else { throw ServerError.invalidRequestBody }
        let session = try await consentService.startTaskSession(
            task: input.path.taskId,
            tag: input.headers.ifMatch,
            session: start.id.requireId(),
            language: start.language,
            startedAt: start.startedAt
        )
        return .ok(.init(headers: .init(cacheControl: .noStore), body: .json(session)))
    }

    func completeParticipantTask(_ input: Operations.CompleteParticipantTask.Input) async throws
        -> Operations.CompleteParticipantTask.Output {
        _ = try AuthContext.checkIsParticipant()
        let tag = input.headers.ifMatch
        guard let session = UUID(uuidString: String(tag.dropFirst().dropLast())), tag == "\"\(session.uuidString.lowercased())\"" else {
            throw ServerError.preconditionFailed("A strong task session tag is required")
        }
        guard case .binary(let body) = input.body else { throw ServerError.invalidRequestBody }
        let receipt = try await consentService.completeTask(
            task: input.path.taskId,
            session: session,
            command: input.headers.idempotencyKey.requireId(),
            body: body,
            publications: publishedStudyService
        )
        return .ok(.init(headers: .init(cacheControl: .noStore), body: .json(receipt)))
    }
}
