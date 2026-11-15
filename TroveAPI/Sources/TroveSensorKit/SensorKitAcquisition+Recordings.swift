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
import TroveAPIClient


extension SensorKitAcquisition {
    static func recordings(for outputs: [Output], native: ConsentSelection, grants: [String: [UUID]]) throws -> [PreparedRecordingTransfer] {
        let documents = outputs.filter { $0.document != nil }
        guard documents.count == native.recordings.count,
              Set(native.recordings.map(\.relativePath)).count == native.recordings.count else { throw AcquisitionError.conversionRefused }
        return try documents.map { output in
            guard let document = output.document, document.content.count == 1,
                  let content = document.content.first,
                  let path = content.attachment.url?.value?.url.absoluteString,
                  let source = native.recordings.first(where: { $0.relativePath == path }),
                  content.format?.code?.value?.string == source.format.rawValue,
                  let end = output.end, let consents = grants[output.url], !consents.isEmpty else {
                throw AcquisitionError.conversionRefused
            }
            return try PreparedRecordingTransfer(
                file: source.file,
                attachmentPath: path,
                outputFullURL: output.url,
                profile: output.profile.rawValue,
                sourceTypeIdentifier: native.sourceToken,
                format: source.format,
                effectiveAt: output.start,
                effectiveEnd: end,
                consentIDs: consents
            )
        }
    }
}
