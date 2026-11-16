//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Vapor


/// Creates a deployment encryption keyring without connecting to application services.
struct CreateSourceIdentityKeyringCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "output", help: "Absolute path of a new owner-only keyring file; the parent directory must exist.") var output: String?
    }

    static let name = "create-source-keyring"

    var help: String { "Create a new source identity encryption keyring. Never overwrites an existing file." }

    func run(using context: CommandContext, signature: Signature) async throws {
        guard let output = signature.output else { throw SourceIdentityKeyring.Failure.creationRefused }
        try SourceIdentityKeyring.create(file: output)
        context.console.print("Created a source identity keyring. Back it up before collecting data; retain it with the database.")
    }
}
