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


struct EvaluateQuestionnaireScenarios: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scenario",
        abstract: "Evaluate named synthetic answer sets against a draft questionnaire component and derive its branching graph.",
        discussion: """
            The file holds `{"scenarios": [{"name": ..., "item": [...]}]}`, with answers in the shape of \
            `QuestionnaireResponse.item`. The result is not stored and creates no participant records. \
            Exit codes: 0 when the graph and every scenario are fully evaluated, 3 when a condition, expression, \
            cycle, answer or a warning in the graph leaves the analysis incomplete. A failed request exits 1 without a result.
            """
    )
    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var draft: DraftAccessOptions
    @Option(transform: CLIInput.uuid) var study: UUID
    @Option(help: "The questionnaire component ID.", transform: CLIInput.uuid) var component: UUID
    @Option(help: "Path to a UTF-8 JSON file with the named scenarios.") var file: String

    static func exitCode(for report: Components.Schemas.QuestionnaireScenarioReport) -> Int32 {
        report.graph.complete && report.scenarios.allSatisfy(\.complete) ? 0 : 3
    }

    mutating func run() async throws {
        let input = try CLIInput.decode(Components.Schemas.QuestionnaireScenarioInput.self, file: file)
        let client = try connection.client()
        let report = try await client.evaluateScenarios(study, component: component, delegation: draft.delegation, input: input)
        try CLIInput.write(report)
        let code = Self.exitCode(for: report)
        if code != 0 {
            throw ExitCode(code)
        }
    }
}
