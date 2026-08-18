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
