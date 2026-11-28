//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveStudyDefinition
import TroveAPIServer


extension Controller {
    private static func evaluate(
        _ bytes: Data, scenarios: [Components.Schemas.QuestionnaireScenario]
    ) throws -> (graph: Components.Schemas.QuestionnaireGraph, results: [Components.Schemas.QuestionnaireScenarioResult]) {
        do {
            return try QuestionnaireScenarios.evaluate(bytes, scenarios: scenarios)
        } catch {
            let detail = switch error {
            case .questionnaire:
                "The questionnaire has more than \(QuestionnaireStructure.maximumItems) items, more than "
                    + "\(ScenarioReportBudget.maximumConditions) conditions or nesting deeper than \(QuestionnaireStructure.maximumDepth) levels"
            case .report:
                "The report exceeds its size limit"
            case .scenario:
                "A scenario has more than \(QuestionnaireScenarios.maximumInstances) item instances"
            }
            throw ServerError(status: .unprocessableContent, title: "Scenario Bounds Exceeded", detail: detail)
        }
    }

    func evaluateQuestionnaireScenarios(
        _ input: Operations.EvaluateQuestionnaireScenarios.Input
    ) async throws -> Operations.EvaluateQuestionnaireScenarios.Output {
        let studyID = try input.path.studyId.requireId()
        let componentID = try input.path.componentId.requireId()
        guard case .json(let body) = input.body else {
            throw ServerError.jsonBodyRequired
        }
        // The revision and its bytes are read together under authorization; evaluation is a pure function of them,
        // so it runs after the study lock is released.
        // The request bounds depend on no study data, so a malformed request takes no lock and records no disclosure.
        try body.validateBounds()
        let (draftRevision, content) = try await studyService.readQuestionnaire(
            studyID: studyID, componentID: componentID, operation: .inspect, purpose: "scenarios"
        )
        let bytes = Data(content.questionnaire.utf8)
        let evaluation = try Self.evaluate(bytes, scenarios: body.scenarios)
        return .ok(.init(body: .json(.init(
            componentId: componentID.uuidString,
            draftRevision: draftRevision.uuidString,
            sha256: FHIRValidationClient.digest(bytes),
            evaluator: QuestionnaireScenarios.evaluator,
            graph: evaluation.graph,
            scenarios: evaluation.results
        ))))
    }
}


extension StudyService {
    /// The stored Questionnaire of a draft component and the draft revision at which it was read.
    func readQuestionnaire(
        studyID: UUID, componentID: UUID, operation: DraftPermission, purpose: String
    ) async throws -> (draftRevision: UUID, content: QuestionnaireContent) {
        try await readDraft(id: studyID, operation: operation) { study, transaction in
            guard let component = try await ComponentRepository(database: transaction).find(id: componentID, studyId: studyID) else {
                throw ServerError.notFound(resource: "Component", identifier: componentID.uuidString)
            }
            guard case .questionnaire(let content) = component.data else {
                throw ServerError(
                    status: .unprocessableContent,
                    title: "Unsupported \(purpose.capitalized)",
                    detail: "Only questionnaire components have \(purpose)"
                )
            }
            return (study.draftRevision, content)
        }
    }
}
