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
    // MARK: - List / Delete

    func getStudiesStudyIdComponents(
        _ input: Operations.GetStudiesStudyIdComponents.Input
    ) async throws -> Operations.GetStudiesStudyIdComponents.Output {
        let studyId = try input.path.studyId.requireId()
        let components = try await componentService.listComponents(studyId: studyId)
        return .ok(.init(body: .json(try components.map { try Components.Schemas.Component($0) })))
    }

    func deleteStudiesStudyIdComponentsComponentId(
        _ input: Operations.DeleteStudiesStudyIdComponentsComponentId.Input
    ) async throws -> Operations.DeleteStudiesStudyIdComponentsComponentId.Output {
        let studyId = try input.path.studyId.requireId()
        let componentId = try input.path.componentId.requireId()
        try await componentService.deleteComponent(
            studyId: studyId, componentId: componentId, expectedRevision: DraftRevision.parse(ifMatch: input.headers.ifMatch)
        )
        return .noContent(.init())
    }

    // MARK: - Informational

    func postStudiesStudyIdComponentsInformational(
        _ input: Operations.PostStudiesStudyIdComponentsInformational.Input
    ) async throws -> Operations.PostStudiesStudyIdComponentsInformational.Output {
        let studyId = try input.path.studyId.requireId()
        guard case .json(let schema) = input.body else {
            throw ServerError.jsonBodyRequired
        }

        let component = try await componentService.createComponent(
            studyId: studyId,
            expectedRevision: DraftRevision.parse(ifMatch: input.headers.ifMatch),
            name: schema.name,
            data: .informational(schema.data)
        )

        return .created(.init(body: .json(try .init(component))))
    }

    func getStudiesStudyIdComponentsInformationalComponentId(
        _ input: Operations.GetStudiesStudyIdComponentsInformationalComponentId.Input
    ) async throws -> Operations.GetStudiesStudyIdComponentsInformationalComponentId.Output {
        let studyId = try input.path.studyId.requireId()
        let componentId = try input.path.componentId.requireId()

        let component = try await componentService.getComponent(
            studyId: studyId,
            id: componentId,
            expectedType: .informational
        )

        return .ok(.init(body: .json(try .init(component))))
    }

    func putStudiesStudyIdComponentsInformationalComponentId(
        _ input: Operations.PutStudiesStudyIdComponentsInformationalComponentId.Input
    ) async throws -> Operations.PutStudiesStudyIdComponentsInformationalComponentId.Output {
        let studyId = try input.path.studyId.requireId()
        let componentId = try input.path.componentId.requireId()

        guard case .json(let schema) = input.body else {
            throw ServerError.jsonBodyRequired
        }

        let component = try await componentService.replaceComponent(
            studyId: studyId,
            id: componentId,
            expectedRevision: DraftRevision.parse(ifMatch: input.headers.ifMatch),
            name: schema.name,
            data: .informational(schema.data)
        )

        return .ok(.init(body: .json(try .init(component))))
    }

    // MARK: - Questionnaire

    func postStudiesStudyIdComponentsQuestionnaire(
        _ input: Operations.PostStudiesStudyIdComponentsQuestionnaire.Input
    ) async throws -> Operations.PostStudiesStudyIdComponentsQuestionnaire.Output {
        let studyId = try input.path.studyId.requireId()
        guard case .json(let schema) = input.body else {
            throw ServerError.jsonBodyRequired
        }

        let component = try await componentService.createQuestionnaire(
            studyID: studyId,
            expectedRevision: DraftRevision.parse(ifMatch: input.headers.ifMatch),
            name: schema.name,
            content: schema.data,
            administrationLanguages: schema.administrationLanguages
        )

        return .created(.init(body: .json(try .init(component))))
    }

    func approveQuestionnaireLanguage(
        _ input: Operations.ApproveQuestionnaireLanguage.Input
    ) async throws -> Operations.ApproveQuestionnaireLanguage.Output {
        guard case .json(let request) = input.body else {
            throw ServerError.jsonBodyRequired
        }
        let result = try await componentService.approveLanguage(
            studyID: input.path.studyId.requireId(),
            componentID: input.path.componentId.requireId(),
            sha256: request.sha256,
            language: request.language
        )
        let body = try Components.Schemas.QuestionnaireLanguageApproval(result.approval)
        return result.created ? .created(.init(body: .json(body))) : .ok(.init(body: .json(body)))
    }

    func revokeQuestionnaireLanguageApproval(
        _ input: Operations.RevokeQuestionnaireLanguageApproval.Input
    ) async throws -> Operations.RevokeQuestionnaireLanguageApproval.Output {
        let approval = try await componentService.revokeLanguageApproval(
            studyID: input.path.studyId.requireId(),
            componentID: input.path.componentId.requireId(),
            approvalID: input.path.approvalId.requireId()
        )
        return .ok(.init(body: .json(try .init(approval))))
    }

    func validateStudyComponent(_ input: Operations.ValidateStudyComponent.Input) async throws -> Operations.ValidateStudyComponent.Output {
        let componentID = try input.path.componentId.requireId()
        let (draftRevision, result) = try await studyValidationService.validateComponent(
            studyID: input.path.studyId.requireId(), componentID: componentID
        )
        return .ok(.init(body: .json(.init(
            componentId: componentID.uuidString,
            draftRevision: draftRevision.uuidString,
            status: result.status,
            sha256: result.sha256,
            language: result.language,
            translationLanguages: result.translationLanguages,
            validatorIdentity: result.validatorIdentity,
            contractVersion: FHIRValidationClient.contractVersion,
            contractRevision: FHIRValidationClient.contractRevision,
            executionCapability: QuestionnaireValidationService.executionCapability,
            diagnostics: result.diagnostics
        ))))
    }

    func getStudiesStudyIdComponentsQuestionnaireComponentId(
        _ input: Operations.GetStudiesStudyIdComponentsQuestionnaireComponentId.Input
    ) async throws -> Operations.GetStudiesStudyIdComponentsQuestionnaireComponentId.Output {
        let studyId = try input.path.studyId.requireId()
        let componentId = try input.path.componentId.requireId()

        let component = try await componentService.getQuestionnaire(studyID: studyId, id: componentId)

        return .ok(.init(body: .json(try .init(component))))
    }

    func putStudiesStudyIdComponentsQuestionnaireComponentId(
        _ input: Operations.PutStudiesStudyIdComponentsQuestionnaireComponentId.Input
    ) async throws -> Operations.PutStudiesStudyIdComponentsQuestionnaireComponentId.Output {
        let studyId = try input.path.studyId.requireId()
        let componentId = try input.path.componentId.requireId()

        guard case .json(let schema) = input.body else {
            throw ServerError.jsonBodyRequired
        }

        let component = try await componentService.replaceQuestionnaire(
            studyID: studyId,
            id: componentId,
            expectedRevision: DraftRevision.parse(ifMatch: input.headers.ifMatch),
            name: schema.name,
            content: schema.data,
            administrationLanguages: schema.administrationLanguages
        )

        return .ok(.init(body: .json(try .init(component))))
    }

    // MARK: - Health Data

    func postStudiesStudyIdComponentsHealthData(
        _ input: Operations.PostStudiesStudyIdComponentsHealthData.Input
    ) async throws -> Operations.PostStudiesStudyIdComponentsHealthData.Output {
        let studyId = try input.path.studyId.requireId()
        guard case .json(let schema) = input.body else {
            throw ServerError.jsonBodyRequired
        }

        let data = StudyDefinition.HealthDataCollectionComponent(schema.data)

        let component = try await componentService.createComponent(
            studyId: studyId,
            expectedRevision: DraftRevision.parse(ifMatch: input.headers.ifMatch),
            name: schema.name,
            data: .healthDataCollection(data)
        )

        return .created(.init(body: .json(try .init(component))))
    }

    func getStudiesStudyIdComponentsHealthDataComponentId(
        _ input: Operations.GetStudiesStudyIdComponentsHealthDataComponentId.Input
    ) async throws -> Operations.GetStudiesStudyIdComponentsHealthDataComponentId.Output {
        let studyId = try input.path.studyId.requireId()
        let componentId = try input.path.componentId.requireId()

        let component = try await componentService.getComponent(
            studyId: studyId,
            id: componentId,
            expectedType: .healthDataCollection
        )

        return .ok(.init(body: .json(try .init(component))))
    }

    func putStudiesStudyIdComponentsHealthDataComponentId(
        _ input: Operations.PutStudiesStudyIdComponentsHealthDataComponentId.Input
    ) async throws -> Operations.PutStudiesStudyIdComponentsHealthDataComponentId.Output {
        let studyId = try input.path.studyId.requireId()
        let componentId = try input.path.componentId.requireId()

        guard case .json(let schema) = input.body else {
            throw ServerError.jsonBodyRequired
        }

        let data = StudyDefinition.HealthDataCollectionComponent(schema.data)

        let component = try await componentService.replaceComponent(
            studyId: studyId,
            id: componentId,
            expectedRevision: DraftRevision.parse(ifMatch: input.headers.ifMatch),
            name: schema.name,
            data: .healthDataCollection(data)
        )

        return .ok(.init(body: .json(try .init(component))))
    }
}
