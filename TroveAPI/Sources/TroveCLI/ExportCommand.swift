// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
// SPDX-License-Identifier: MIT

import ArgumentParser
import Crypto
import Foundation
import OpenAPIRuntime
import TroveAPIClient


struct ExportCommand: AsyncParsableCommand {
    struct Options: ParsableArguments {
        @OptionGroup var connection: ConnectionOptions
        @Option(transform: CLIInput.uuid) var study: UUID
        @Argument(transform: CLIInput.uuid) var export: UUID
    }

    struct Create: AsyncParsableCommand {
        @OptionGroup var connection: ConnectionOptions
        @Option(transform: CLIInput.uuid) var study: UUID
        @Option(transform: CLIInput.uuid) var requestId: UUID
        @Flag var history = false
        @Flag(help: "Capture membership and leave execution queued.") var queueOnly = false

        func run() async throws {
            let session = try connection.client()
            let job = try await session.request(revision: nil) { client in
                try await client.createStudyExport(.init(
                    path: .init(studyId: study.uuidString),
                    body: .json(.init(requestId: requestId.uuidString, versions: history ? .history : .current))
                )).ok.body.json
            }
            guard UUID(uuidString: job.studyId) == study, let id = UUID(uuidString: job.id) else { throw CLIError.requestFailed }
            if queueOnly || job.status == .ready {
                try CLIInput.write(job)
            } else {
                let ready = try await session.request(revision: nil) { client in
                    try await client.executeStudyExport(.init(path: .init(studyId: study.uuidString, exportId: id.uuidString))).ok.body.json
                }
                try CLIInput.write(ready)
            }
        }
    }

    struct Get: AsyncParsableCommand {
        @OptionGroup var options: Options

        func run() async throws {
            let result = try await options.connection.client().request(revision: nil) { client in
                try await client.getStudyExport(.init(
                    path: .init(studyId: options.study.uuidString, exportId: options.export.uuidString)
                )).ok.body.json
            }
            try CLIInput.write(result)
        }
    }

    struct Execute: AsyncParsableCommand {
        @OptionGroup var options: Options

        func run() async throws {
            let result = try await options.connection.client().request(revision: nil) { client in
                try await client.executeStudyExport(.init(
                    path: .init(studyId: options.study.uuidString, exportId: options.export.uuidString)
                )).ok.body.json
            }
            try CLIInput.write(result)
        }
    }

    struct Page: AsyncParsableCommand {
        @OptionGroup var options: Options
        @Option var offset = 0
        @Option var limit = 20

        func run() async throws {
            guard offset >= 0, (1...100).contains(limit) else { throw CLIError.invalidInput }
            let result = try await options.connection.client().request(revision: nil) { client in
                try await client.getStudyExportPage(.init(
                    path: .init(studyId: options.study.uuidString, exportId: options.export.uuidString),
                    query: .init(offset: offset, limit: limit)
                )).ok.body.json
            }
            try CLIInput.write(result)
        }
    }

    struct Download: AsyncParsableCommand {
        @OptionGroup var options: Options

        func run() async throws {
            let data = try await options.connection.client().request(revision: nil) { client in
                let manifest = try await client.getStudyExport(.init(
                    path: .init(studyId: options.study.uuidString, exportId: options.export.uuidString)
                )).ok.body.json
                guard UUID(uuidString: manifest.studyId) == options.study, UUID(uuidString: manifest.id) == options.export,
                      manifest.status == .ready, let size = manifest.byteCount, (0...96 * 1024 * 1024).contains(size),
                      let checksum = manifest.sha256 else { throw CLIError.requestFailed }
                let body = try await client.downloadStudyExport(.init(
                    path: .init(studyId: options.study.uuidString, exportId: options.export.uuidString)
                )).ok.body.binary
                let bytes = try await Data(collecting: body, upTo: size)
                guard bytes.count == size, SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == checksum else {
                    throw CLIError.requestFailed
                }
                return bytes
            }
            try CLIInput.writeExact(data)
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "export", subcommands: [Create.self, Get.self, Execute.self, Page.self, Download.self]
    )
}
