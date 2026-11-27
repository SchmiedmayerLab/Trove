// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import Foundation
@_spi(APISupport) import GroveStudyDefinition
import TroveAPIServer
import ZIPFoundation


/// Writes the immutable study archive.
extension StudyBundleService {
    func writeBundleZip(
        studyId: UUID,
        definition: StudyDefinition,
        files: [StudyBundle.FileResourceInput],
        collectionPolicy: PublishedCollectionPolicy,
        taskDefinitions: Data?
    ) throws -> Data {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleURL = tempDir.appendingPathComponent("\(studyId).\(StudyBundle.fileExtension)", isDirectory: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let policyURL = tempDir.appendingPathComponent(PublishedCollectionPolicy.filename)
        try collectionPolicy.archiveBytes().write(to: policyURL, options: .atomic)
        let policyFile = StudyBundle.FileResourceInput(pathInBundle: PublishedCollectionPolicy.filename, contentsOf: policyURL)

        let bundle: StudyBundle
        do {
            let archiveFiles = try files + [policyFile] + Self.taskDefinitionsFile(taskDefinitions, in: tempDir)
            bundle = try StudyBundle.writeToDisk(at: bundleURL, definition: definition, files: archiveFiles)
        } catch StudyBundle.CreateBundleError.failedValidation {
            throw ServerError(
                status: .unprocessableContent, title: "Invalid Study Bundle", detail: "Study resources do not satisfy bundle requirements"
            )
        } catch is DecodingError {
            throw ServerError(status: .unprocessableContent, title: "Invalid Study Bundle", detail: "Study resources contain invalid structured data")
        } catch {
            throw ServerError.internalServerError("Failed to build study bundle")
        }
        guard definition.validate(in: bundle) else {
            throw ServerError(
                status: .unprocessableContent,
                title: "Invalid Study Bundle",
                detail: "Study schedules and resources must reference existing components"
            )
        }

        return try zipDirectory(at: bundleURL)
    }

    private func zipDirectory(at directoryURL: URL) throws -> Data {
        let archive = try Archive(accessMode: .create)

        let resolvedDirectory = directoryURL.resolvingSymlinksInPath()
        let baseName = resolvedDirectory.lastPathComponent
        let basePath = resolvedDirectory.path

        guard let enumerator = FileManager.default.enumerator(
            at: resolvedDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            throw ServerError.internalServerError("Failed to enumerate bundle directory")
        }

        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
            let resolvedFile = fileURL.resolvingSymlinksInPath()
            let relativePath = resolvedFile.path.replacingOccurrences(of: basePath + "/", with: "")
            let entryPath = "\(baseName)/\(relativePath)"

            if resourceValues.isDirectory == true {
                try archive.addEntry(
                    with: entryPath + "/",
                    type: .directory,
                    uncompressedSize: Int64(0),
                    provider: { (_: Int64, _: Int) in Data() }
                )
            } else {
                let fileData = try Data(contentsOf: fileURL)
                try archive.addEntry(
                    with: entryPath,
                    type: .file,
                    uncompressedSize: Int64(fileData.count),
                    compressionMethod: .deflate,
                    provider: { (position: Int64, size: Int) in
                        fileData[Int(position)..<(Int(position) + size)]
                    }
                )
            }
        }

        guard let data = archive.data else {
            throw ServerError.internalServerError("Failed to create ZIP archive")
        }

        return data
    }
}
