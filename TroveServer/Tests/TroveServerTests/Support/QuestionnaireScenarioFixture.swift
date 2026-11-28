//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TroveAPIServer
@testable import TroveServer


/// The scenario fixtures that the Swift and TypeScript evaluators share, stored once in `TroveAPI/Tests/Fixtures`.
///
/// Each file holds the evaluator identity it was written for, a `questionnaire`, a `request` in the shape of the scenarios
/// operation's body and the `expected` graph and scenario results. Every member that `expected` states must equal the
/// evaluator's output; a member it leaves out is not compared, and arrays must have the same length.
struct QuestionnaireScenarioFixture: Sendable, CustomTestStringConvertible {
    private struct Output: Encodable {
        let graph: Components.Schemas.QuestionnaireGraph
        let scenarios: [Components.Schemas.QuestionnaireScenarioResult]
    }

    static let directory = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "../../../../TroveAPI/Tests/Fixtures/questionnaire-scenarios")
        .standardized

    let file: String

    var testDescription: String {
        file
    }

    static func all() throws -> [Self] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }
            .sorted()
            .map(Self.init(file:))
    }

    /// The members of the expected output that differ from the evaluator's output, by fixture path.
    static func mismatches(expected: ScenarioJSON, actual: ScenarioJSON?, path: String) -> [String] {
        switch expected {
        case .object(let members):
            guard let actual = actual?.object else {
                return ["\(path): expected an object, found \(String(describing: actual))"]
            }
            return members.keys.sorted().flatMap { key in
                mismatches(expected: members[key] ?? .null, actual: actual[key], path: "\(path).\(key)")
            }
        case .array(let elements):
            guard let actual = actual?.array, actual.count == elements.count else {
                return ["\(path): expected \(elements.count) elements, found \(String(describing: actual))"]
            }
            return zip(elements, actual).enumerated().flatMap { index, pair in
                mismatches(expected: pair.0, actual: pair.1, path: "\(path)[\(index)]")
            }
        default:
            return expected == actual ? [] : ["\(path): expected \(expected), found \(String(describing: actual))"]
        }
    }

    func json() throws -> ScenarioJSON {
        try JSONDecoder().decode(ScenarioJSON.self, from: Data(contentsOf: Self.directory.appending(path: file)))
    }

    /// The evaluator's output for the fixture's questionnaire and request, in the fixture's JSON form.
    func evaluate() throws -> ScenarioJSON {
        let fixture = try json()
        let bytes = try JSONEncoder().encode(try #require(fixture["questionnaire"]))
        let input = try #require(fixture["request"]?.converted(to: Components.Schemas.QuestionnaireScenarioInput.self))
        let (graph, results) = try QuestionnaireScenarios.evaluate(bytes, scenarios: input.scenarios)
        return try #require(ScenarioJSON.from(Output(graph: graph, scenarios: results)))
    }
}
