//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import TroveAPIServer


extension Controller {
    func getStudyRecording(_ input: Operations.GetStudyRecording.Input) async throws -> Operations.GetStudyRecording.Output {
        let download = try await studyService.recording(
            studyID: input.path.studyId.requireId(),
            grantID: input.path.grantId.requireId(),
            versions: input.query.versions == .history ? .history : .current
        )
        return .ok(.init(
            headers: .init(
                cacheControl: .noStore,
                contentDisposition: download.media.contentDisposition,
                xRecordingContentType: download.media.contentType
            ),
            body: .binary(download.body)
        ))
    }
}
