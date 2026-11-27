// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
@_spi(APISupport) import GroveStudyDefinition
import ZIPFoundation


extension StudyBundleService {
    static var missingDefinitionNamespace: ServerError {
        .internalServerError("Publishing scheduled questionnaires requires TROVE_STUDY_CANONICAL_BASE")
    }

    static func definitionNamespace(_ value: String?) throws -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }
        guard StudyTaskDefinitions.validBase(value) else {
            throw ServerError.internalServerError("TROVE_STUDY_CANONICAL_BASE must be an absolute HTTP(S) URL without query or fragment")
        }
        return value
    }

    /// The task definitions retained at the archive root, if the revision has any.
    static func taskDefinitions(in bundle: Data, study: UUID) throws -> Data? {
        let archive = try Archive(data: bundle, accessMode: .read)
        let path = "\(study).\(StudyBundle.fileExtension)/" + StudyTaskDefinitions.filename
        let matches = archive.filter { $0.path == path }
        guard !matches.isEmpty else {
            return nil
        }
        guard matches.count == 1, let entry = matches.first, entry.type == .file else { throw StudyTaskDefinitions.invalid }
        var remaining = FHIRValidationClient.maximumBytes
        return try extract(entry, from: archive, remainingBytes: &remaining)
    }

    private static func extract(_ entry: Entry, from archive: Archive, remainingBytes: inout Int) throws -> Data {
        var content = Data()
        _ = try archive.extract(entry) { chunk in
            guard chunk.count <= remainingBytes else { throw StudyTaskDefinitions.invalid }
            remainingBytes -= chunk.count
            content.append(chunk)
        }
        return content
    }

    /// The archive entry of a revision's task definitions, written into the archive's temporary directory.
    static func taskDefinitionsFile(_ definitions: Data?, in directory: URL) throws -> [StudyBundle.FileResourceInput] {
        guard let definitions else {
            return []
        }
        let url = directory.appendingPathComponent(StudyTaskDefinitions.filename)
        try definitions.write(to: url)
        return [.init(pathInBundle: StudyTaskDefinitions.filename, contentsOf: url)]
    }

    /// The exact instrument of every scheduled questionnaire component.
    func scheduledInstruments(scheduled: Set<UUID>, inputs: [QuestionnaireResource]) throws -> [UUID: String] {
        var pins: [UUID: String] = [:]
        for input in inputs where scheduled.contains(input.componentID) {
            let resource = try StudyProjectionJSON.readResult(input.bytes)
            guard let url = resource["url"]?.string, let version = resource["version"]?.string else {
                throw ServerError(
                    status: .unprocessableContent,
                    title: "Invalid Study Bundle",
                    detail: "A scheduled questionnaire needs a canonical url and version"
                )
            }
            pins[input.componentID] = url + "|" + version
        }
        return pins
    }

    /// Every revision that schedules a questionnaire retains the definitions its task occurrences instantiate.
    /// Without a configured namespace, `unconfigured` is set so the caller fails after the draft passed every other check.
    func taskDefinitions(
        study: UUID, revision: Int, schedules: [StudyDefinition.ComponentSchedule], inputs: [QuestionnaireResource]
    ) throws -> (graph: Data?, unconfigured: Bool) {
        let instruments = try scheduledInstruments(scheduled: Set(schedules.map(\.componentId)), inputs: inputs)
        guard !instruments.isEmpty else {
            return (nil, false)
        }
        guard let canonicalBase else {
            return (nil, true)
        }
        return (try StudyTaskDefinitions.build(study: study, revision: revision, base: canonicalBase, instruments: instruments), false)
    }
}
