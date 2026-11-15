//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import OpenAPIRuntime


extension StudyService {
    func recording(studyID: UUID, grantID: UUID, versions: StudyDataQuery.Versions) async throws -> StudyRecordingDownload {
        let actor = try AuthContext.checkIsResearcher()
        _ = try await authorizationService.checkResearcherHasStudyDataAccess(studyID, actor: actor, on: repository.database)
        guard !repository.database.inTransaction else { throw AuditError.disclosureInsideTransaction }
        let (candidate, attachment, media) = try await repository.database.transaction { transaction in
            let query = StudyDataQuery(database: transaction)
            let candidate = try await query.recording(grantID: grantID, studyID: studyID, versions: versions)
            let fence = try await query.fence(candidate, studyID: studyID, versions: versions)
            let study = try await self.repository.lockStudy(id: studyID, on: transaction)
            try await self.authorizationService.checkResearcherHasStudyDataAccess(study, actor: actor, on: transaction)
            guard fence.grants.contains(where: { $0.id == grantID }), let output = candidate.outputs.first else {
                throw ServerError.notFound("Study recording not found")
            }
            let event = try await StudyDataExportStore(database: transaction).retainedEvent(id: output.eventID)
            guard let attachment = event.recordings.first(where: { $0.declaration.output.fullURL == output.fullURL }) else {
                throw ServerError.notFound("Study recording not found")
            }
            let media = try StudyRecordingMedia(event: event, outputFullURL: output.fullURL)
            return (candidate, attachment, media)
        }
        // Do not hold participant/enrollment locks during object reads and complete byte verification.
        let file = try await recordingDownloads.prepare(attachment)
        try await repository.database.transaction { transaction in
            let fence = try await StudyDataQuery(database: transaction).fence(candidate, studyID: studyID, versions: versions)
            let study = try await self.repository.lockStudy(id: studyID, on: transaction)
            try await self.authorizationService.checkResearcherHasStudyDataAccess(study, actor: actor, on: transaction)
            guard fence.grants.contains(where: { $0.id == grantID }) else { throw ServerError.notFound("Study recording not found") }
            guard actor.tokenExpiresAt.map({ $0 > Date() }) ?? true else { throw ServerError.invalidToken }
            try Task.checkCancellation()
            try await AuditRepository.recordDisclosureIntent(.init(
                context: actor.auditContext,
                action: .studyRecordingDisclosure,
                scope: .study(studyID: studyID, groupID: study.$group.id),
                target: .init(id: grantID, version: versions == .current ? "current" : "history")
            ), on: transaction)
        }
        return .init(body: RecordingDownloadBody(file: file).body, media: media)
    }
}
