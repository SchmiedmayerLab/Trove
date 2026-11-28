// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
import GroveLocalization
@_spi(APISupport) import GroveStudyDefinition
import ZIPFoundation


extension StudyBundleService {
    /// Reads the exact component version retained in the study publication.
    static func publishedQuestionnaire(
        in bundle: Data, studyID: UUID, componentID: UUID, baseLanguage: String, sha256: String
    ) throws -> Data {
        let unavailable = ServerError.internalServerError("The published Questionnaire does not match the task")
        guard let locale = LocalizationKey(baseLanguage) else { throw unavailable }
        let path = "\(studyID).\(StudyBundle.fileExtension)/questionnaire/\(componentID.uuidString.lowercased())+\(locale.description).json"
        let archive = try Archive(data: bundle, accessMode: .read)
        let matches = archive.filter { $0.path == path }
        guard matches.count == 1, let entry = matches.first, entry.type == .file else { throw unavailable }
        var bytes = Data()
        _ = try archive.extract(entry) { chunk in
            guard bytes.count + chunk.count <= ArtifactReference.Purpose.publication.maximumBytes else { throw unavailable }
            bytes.append(chunk)
        }
        guard FHIRValidationClient.digest(bytes) == sha256 else { throw unavailable }
        return bytes
    }
}
