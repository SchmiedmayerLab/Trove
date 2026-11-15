//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import GroveFHIRContract
import Testing
@testable import TroveServer


struct StudyRecordingMediaTests {
    @Test(arguments: StudyRecordingMedia.ContentType.allCases)
    func registeredMediaPreservesItsExactRepresentation(media: StudyRecordingMedia.ContentType) throws {
        let format = try #require(RegisteredRecordingFormat.allCases.first { $0.registeredContentTypes.contains(media.rawValue) })
        let result = try StudyRecordingMedia(format: format, mediaType: media.rawValue)
        #expect(result.contentType == media)
        #expect(result.contentDisposition.hasPrefix("attachment; filename=recording."))
        #expect(!result.contentDisposition.contains("; fhirVersion"))
    }

    @Test(arguments: ["text/html", "application/json", "text/csv; charset=utf-8", "text/csv\r\nX-Injected: yes"])
    func formatMismatchAndUnregisteredMediaAreRefused(media: String) {
        #expect(throws: (any Error).self) {
            try StudyRecordingMedia(format: .locationTrackSamples, mediaType: media)
        }
    }
}
