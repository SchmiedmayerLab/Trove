//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import ArgumentParser
import Foundation
import TroveAPIClient


struct GetStudyData: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "data",
        abstract: "Read one authorized page of study measurements with exact FHIR Bundles.",
        discussion: "Requires interactive researcher and group data-reader access. Pages form a live view, not a frozen dataset. "
            + "Bundle bytes are Base64 encoded to preserve numeric values. Superseded versions are not additional measurements."
    )
    @OptionGroup var connection: ConnectionOptions
    @Argument(transform: CLIInput.uuid) var study: UUID
    @Option(help: "Maximum selected records, from 1 to 100. Reduce for large records.") var limit: Int = 20
    @Option(help: "Opaque nextBefore from a page of this study and version view.", transform: CLIInput.uuid) var before: UUID?
    @Flag(help: "Include superseded versions, marked isCurrent=false. The default selects current versions only.") var history = false

    func validate() throws {
        guard (1...100).contains(limit) else {
            throw ValidationError("Records per page must be between 1 and 100.")
        }
    }

    mutating func run() async throws {
        let client = try connection.client()
        let page = try await client.getStudyData(study, versions: history ? .history : .current, limit: limit, before: before)
        try CLIInput.write(page)
    }
}
