//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import ModelsR4
import OpenAPIRuntime
import TroveAPIServer


extension Controller {
    func getParticipantFhirResource(
        _ input: Operations.GetParticipantFhirResource.Input
    ) async throws -> Operations.GetParticipantFhirResource.Output {
        let records = try await fhirResourceService.listObservations(
            code: input.query.code,
            start: input.query.start,
            end: input.query.end
        )
        return .ok(.init(body: .json(try records.map { try $0.responseSchema() })))
    }

    func postParticipantFhirResource(
        _ input: Operations.PostParticipantFhirResource.Input
    ) async throws -> Operations.PostParticipantFhirResource.Output {
        guard case .json(let schema) = input.body else {
            throw ServerError.jsonBodyRequired
        }
        let resource = try ResourceProxy(schema)
        try await fhirResourceService.createResource(resource: resource)
        return .created(.init())
    }
}
