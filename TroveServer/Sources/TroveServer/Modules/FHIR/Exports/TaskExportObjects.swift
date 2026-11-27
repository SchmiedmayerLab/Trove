// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Fluent
import Foundation


/// Object-storage bytes of the task members, read before the export transaction so that no download runs while it holds
/// the participant, enrollment and study locks. Each entry keeps the locator and digest it was verified against. The
/// transaction uses an entry only after it rechecks the current retained record against the same locator and digest.
struct TaskExportObjects: Sendable {
    private struct Object: Sendable {
        let key: String
        let digest: String
        let bytes: Data
    }

    private struct Response {
        let enrollment: UUID
        let completion: TaskExportMember.Completion
        let row: StoredArtifact
    }

    private var objects: [UUID: Object] = [:]

    /// Reads the publication archive of every revision the members name and, with a byte budget, the accepted response of
    /// every completion. Responses whose retained sizes exceed the budget are refused before any of them is downloaded.
    static func fetch(_ tasks: [TaskExportMember], using artifacts: ArtifactStore, responseBudget: Int? = nil) async throws -> Self {
        var result = Self()
        var instruments: [UUID: PublishedStudyService.TaskInstrument] = [:]
        for task in tasks where instruments[task.instrument.publicationID] == nil {
            instruments[task.instrument.publicationID] = task.instrument
        }
        for instrument in instruments.values {
            guard let publication = try await PublishedStudy.find(instrument.publicationID, on: artifacts.database),
                  publication.artifactID == instrument.artifactID else { throw ServerError.forbidden }
            let expected = (key: publication.bundleKey, digest: publication.bundleDigest)
            let bytes = try await artifacts.download(
                id: instrument.artifactID, ownerID: instrument.studyID, purpose: .publication, expected: expected
            )
            result.objects[instrument.artifactID] = .init(key: expected.key, digest: expected.digest, bytes: bytes)
        }
        guard let responseBudget else {
            return result
        }
        var responses: [Response] = []
        for task in tasks {
            guard let completion = task.completion else {
                continue
            }
            guard let row = try await StoredArtifact.find(completion.responseArtifact, on: artifacts.database) else { throw ServerError.forbidden }
            responses.append(.init(enrollment: task.enrollment, completion: completion, row: row))
        }
        guard responses.reduce(0, { $0 + $1.row.byteCount }) <= responseBudget else { throw StudyProjectionJSON.Failure.outputTooLarge }
        for response in responses {
            let completion = response.completion
            let expected = (key: try response.row.reference().key, digest: completion.responseDigest)
            let bytes = try await artifacts.download(
                id: completion.responseArtifact, ownerID: response.enrollment, purpose: .taskResponse, expected: expected
            )
            result.objects[completion.responseArtifact] = .init(key: expected.key, digest: expected.digest, bytes: bytes)
        }
        return result
    }

    /// The bytes read before the transaction, checked against the current retained record.
    /// A member that was not read before the transaction started asks the caller to retry.
    func bytes(
        id: UUID, ownerID: UUID, purpose: ArtifactReference.Purpose, expected: (key: String, digest: String), using artifacts: ArtifactStore
    ) async throws -> Data {
        guard let object = objects[id], object.key == expected.key, object.digest == expected.digest else {
            throw ServerError.conflict("Study tasks changed; retry the same request")
        }
        return try await artifacts.check(object.bytes, id: id, ownerID: ownerID, purpose: purpose, expected: expected)
    }
}
