//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import ArgumentParser
import Foundation


struct GetStudyRecording: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recording",
        abstract: "Save one authorized recording as its original CSV bytes.",
        discussion: "Use the study and grant IDs from the recording attachment URL in a study data Bundle. "
            + "Requires interactive researcher and group data-reader access. Existing files are never replaced."
    )
    @OptionGroup var connection: ConnectionOptions
    @Argument(transform: CLIInput.uuid) var study: UUID
    @Argument(transform: CLIInput.uuid) var grant: UUID
    @Option(help: "New output file in an existing directory. The saved file is readable only by its owner.") var output: String
    @Option(help: "Maximum downloaded bytes, from 1 through 2147483647 (default 512 MiB).") var maxBytes: Int64 = 512 * 1024 * 1024
    @Flag(help: "Use the history view when the attachment URL includes versions=history.") var history = false

    func validate() throws {
        guard (1...Int64(Int32.max)).contains(maxBytes) else {
            throw ValidationError("Maximum bytes must be between 1 and 2147483647.")
        }
    }

    mutating func run() async throws {
        let destination = try RecordingOutput(path: output)
        try await connection.withRecordingClient { client in
            let body = try await client.getStudyRecording(study, grant: grant, versions: history ? .history : .current)
            try await destination.save(body, maximumByteCount: maxBytes)
        }
    }
}
