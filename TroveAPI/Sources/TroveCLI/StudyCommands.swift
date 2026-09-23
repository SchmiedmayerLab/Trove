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


struct CreateStudy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a study from a StudyCreateInput JSON file.")
    @OptionGroup var connection: ConnectionOptions
    @Option(transform: CLIInput.uuid) var group: UUID
    @Option(help: "Path to a StudyCreateInput JSON file.") var file: String

    mutating func run() async throws {
        let input = try CLIInput.decode(Components.Schemas.StudyCreateInput.self, file: file)
        let client = try connection.client()
        try CLIInput.write(try await client.createStudy(group: group, input: input))
    }
}


struct GetStudy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Read a study draft and its current revision.")
    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var draft: DraftAccessOptions
    @Argument(transform: CLIInput.uuid) var study: UUID

    mutating func run() async throws {
        let client = try connection.client()
        try CLIInput.write(try await client.getStudy(study, delegation: draft.delegation))
    }
}


struct EditStudy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "edit", abstract: "Apply a typed partial update to a reviewed draft.")
    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var draft: DraftAccessOptions
    @Argument(transform: CLIInput.uuid) var study: UUID
    @Option(help: "The draft revision captured when preparing this edit.", transform: CLIInput.uuid) var revision: UUID
    @Option(help: "Path to a StudyPatchInput JSON file.") var file: String

    mutating func run() async throws {
        let input = try CLIInput.decode(Components.Schemas.StudyPatchInput.self, file: file)
        let client = try connection.client()
        try CLIInput.write(try await client.editStudy(study, revision: revision, delegation: draft.delegation, input: input))
    }
}


struct ValidateStudy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "validate", abstract: "Validate and capture an immutable publication candidate.")
    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var draft: DraftAccessOptions
    @Argument(transform: CLIInput.uuid) var study: UUID
    @Option(help: "The draft revision to validate.", transform: CLIInput.uuid) var revision: UUID

    mutating func run() async throws {
        let client = try connection.client()
        try CLIInput.write(try await client.validateStudy(study, revision: revision, delegation: draft.delegation))
    }
}


struct PublishStudy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "publish",
        abstract: "Publish only the exact reviewed validation candidate using administrator authority.",
        discussion: "This never validates or selects the current draft implicitly. Retain the validation ID and revision for an exact retry."
    )
    @OptionGroup var connection: ConnectionOptions
    @Argument(transform: CLIInput.uuid) var study: UUID
    @Option(help: "The draft revision in the reviewed validation receipt.", transform: CLIInput.uuid) var revision: UUID
    @Option(help: "The immutable validation candidate ID you reviewed.", transform: CLIInput.uuid) var validation: UUID

    mutating func run() async throws {
        let client = try connection.client()
        try CLIInput.write(try await client.publishStudy(study, revision: revision, validation: validation))
    }
}


struct ImportQuestionnaire: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import a FHIR Questionnaire JSON file into a reviewed draft without rewriting the resource."
    )
    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var draft: DraftAccessOptions
    @Option(transform: CLIInput.uuid) var study: UUID
    @Option(help: "The draft revision captured before this import.", transform: CLIInput.uuid) var revision: UUID
    @Option(help: "Component display name; independent of the FHIR resource id.") var name: String
    @Option(help: "Language-region locale, for example en-US.", transform: CLIInput.localization) var locale: Components.Schemas.LocalizationKey
    @Option(help: "Path to an unmodified UTF-8 FHIR Questionnaire JSON file.") var file: String

    mutating func run() async throws {
        let input = try CLIInput.questionnaire(file: file, name: name, locale: locale)
        let client = try connection.client()
        try CLIInput.write(try await client.importQuestionnaire(study, revision: revision, delegation: draft.delegation, input: input))
    }
}
