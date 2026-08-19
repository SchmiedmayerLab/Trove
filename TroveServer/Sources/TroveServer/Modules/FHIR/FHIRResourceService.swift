//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Grove
import ModelsR4


final class FHIRResourceService: Module, @unchecked Sendable {
    @Dependency(FHIRResourceRepository.self) var repository
    @Dependency(ProfileService.self) var profileService

    func createResource(resource: ResourceProxy) async throws {
        guard case .observation = resource else {
            throw ServerError.badRequest("Only FHIR Observation resources are supported")
        }

        let participant = try await profileService.getProfile()
        let participantId = try participant.requireId()

        let record = FHIRResourceRecord(resource, participantID: participantId)
        try await repository.create(record)
    }
}
