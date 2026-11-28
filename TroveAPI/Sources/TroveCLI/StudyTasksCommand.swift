//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import ArgumentParser
import Foundation


struct GetStudyTasks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tasks", abstract: "Read a page of current study questionnaire assignments.")
    @OptionGroup var connection: ConnectionOptions
    @Argument(transform: CLIInput.uuid) var study: UUID
    @Option(help: "Maximum assignments per page, from 1 to 100.") var limit = 50
    @Option(help: "Continuation from the previous page of this study.") var after: String?

    mutating func run() async throws {
        let page = try await connection.client().getStudyTasks(study, after: after, limit: limit)
        try CLIInput.write(page)
    }
}
