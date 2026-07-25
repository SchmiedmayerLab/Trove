//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import ModelsR4
import Spezi


final class FHIRResourceService: Module, @unchecked Sendable {
    @Dependency(FHIRResourceRepository.self) var repository
    @Dependency(ProfileService.self) var profileService

    func createResource(resource: ResourceProxy) async throws {
        let participant = try await profileService.getProfile()
        let participantId = try participant.requireId()

        let record = FHIRResourceRecord(resource, participantID: participantId)
        try await repository.create(record)
    }
}
