//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import ModelsR4
import OpenAPIRuntime
import TroveAPITypes


struct StudyRecordingDownload: Sendable {
    let body: HTTPBody
    let media: StudyRecordingMedia
}

/// Saved-file metadata comes from immutable custody evidence, never a storage response or a request parameter.
struct StudyRecordingMedia: Sendable {
    typealias ContentType = Operations.GetStudyRecording.Output.Ok.Headers.XRecordingContentTypePayload

    let contentType: ContentType

    var contentDisposition: String {
        let suffix: String = switch contentType {
        case .textCsv: "csv"
        case .applicationJson, .applicationFhirJson,
             .applicationFhirJson_semi_FhirVersion_equals_1_0, .applicationFhirJson_semi_FhirVersion_equals_4_0: "json"
        case .applicationOctetStream: "bin"
        case .applicationHl7CdaXml: "xml"
        }
        return "attachment; filename=recording.\(suffix)"
    }

    init(format: RegisteredRecordingFormat, mediaType: String) throws {
        guard format.registeredContentTypes.contains(mediaType), let contentType = ContentType(rawValue: mediaType) else {
            throw ServerError.internalServerError("Recording media is unavailable")
        }
        self.contentType = contentType
    }

    init(event: ValidatedExchangeEvent, outputFullURL: String) throws {
        let bundle = try JSONDecoder().decode(ModelsR4.Bundle.self, from: event.rawBytes)
        let entries = (bundle.entry ?? []).filter { $0.fullUrl?.value?.url.absoluteString == outputFullURL }
        guard entries.count == 1, case .documentReference(let document)? = entries.first?.resource,
              document.content.count == 1, let content = document.content.first,
              content.format?.system?.value?.url.absoluteString == FHIRRecordingProjection.formatSystem,
              let code = content.format?.code?.value?.string, let format = RegisteredRecordingFormat(rawValue: code),
              let media = content.attachment.contentType?.value?.string else {
            throw ServerError.internalServerError("Recording media is unavailable")
        }
        try self.init(format: format, mediaType: media)
    }
}
