//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPIServer


extension Controller {
    func createStudyDelegation(_ input: Operations.CreateStudyDelegation.Input) async throws -> Operations.CreateStudyDelegation.Output {
        guard case .json(let body) = input.body else { throw ServerError.jsonBodyRequired }
        let grant = try await delegationService.create(
            studyID: input.path.studyId.requireId(),
            clientID: body.clientId,
            preset: .init(body.preset),
            expiresAt: body.expiresAt
        )
        return .created(.init(body: .json(.init(grant))))
    }

    func listStudyDelegations(_ input: Operations.ListStudyDelegations.Input) async throws -> Operations.ListStudyDelegations.Output {
        let page = try await delegationService.list(
            studyID: input.path.studyId.requireId(), before: input.query.before.map { try $0.requireId() }, limit: input.query.limit ?? 50
        )
        let response = Components.Schemas.StudyDelegationPage(
            items: page.grants.map(Components.Schemas.StudyDelegation.init),
            nextBefore: page.nextBefore?.uuidString
        )
        return .ok(.init(body: .json(response)))
    }

    func revokeStudyDelegation(_ input: Operations.RevokeStudyDelegation.Input) async throws -> Operations.RevokeStudyDelegation.Output {
        let grant = try await delegationService.revoke(
            studyID: input.path.studyId.requireId(), delegationID: input.path.delegationId.requireId()
        )
        return .ok(.init(body: .json(.init(grant))))
    }
}


extension DelegationPreset {
    init(_ value: Components.Schemas.StudyDelegationPreset) {
        switch value {
        case .inspectStudy: self = .inspectStudy
        case .editStudyDraft: self = .editStudyDraft
        }
    }
}


extension Components.Schemas.StudyDelegation {
    init(_ grant: DelegationGrant) {
        let preset: Components.Schemas.StudyDelegationPreset = switch grant.preset {
        case .inspectStudy: .inspectStudy
        case .editStudyDraft: .editStudyDraft
        }
        self.init(
            id: grant.id.uuidString,
            studyId: grant.studyID.uuidString,
            clientId: grant.clientID,
            preset: preset,
            createdAt: grant.createdAt,
            expiresAt: grant.expiresAt,
            revokedAt: grant.revokedAt
        )
    }
}
