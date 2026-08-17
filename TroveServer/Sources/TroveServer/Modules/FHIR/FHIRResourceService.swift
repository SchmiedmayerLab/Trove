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
        let participant = try await profileService.getProfile()
        let participantId = try participant.requireId()

        let record = FHIRResourceRecord(resource, participantID: participantId)
        try await repository.create(record)
    }

    func listObservations(code: String, start: Date, end: Date) async throws -> [FHIRResourceRecord] {
        guard start <= end else {
            throw ServerError.badRequest("The observation time window must start before it ends")
        }

        let participant = try await profileService.getProfile()
        return try await repository.listObservations(
            participantID: try participant.requireId(),
            code: code,
            start: start,
            end: end
        )
    }
}
