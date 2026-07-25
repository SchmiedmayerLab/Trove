//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import Spezi


final class ProfileService: Module, @unchecked Sendable {
    @Dependency(ProfileRepository.self) var repository
    @Dependency(AuthorizationService.self) var authorizationService

    func createProfile(input: ParticipantProfileInput) async throws -> Participant {
        let context = try authorizationService.checkIsParticipant()

        let participant = Participant(
            identityProviderId: context.subject,
            firstName: input.firstName,
            lastName: input.lastName,
            email: context.email,
            gender: input.gender,
            dateOfBirth: input.dateOfBirth,
            region: input.region,
            language: input.language,
            phoneNumber: input.phoneNumber
        )

        do {
            return try await repository.create(participant)
        } catch where (error as? any DatabaseError)?.isConstraintFailure == true {
            throw ServerError.conflict(resource: "Participant", identifier: context.subject)
        }
    }

    func getProfile() async throws -> Participant {
        let context = try authorizationService.checkIsParticipant()

        guard let participant = try await repository.findByIdentityProviderId(context.subject) else {
            throw ServerError.notFound(resource: "Participant", identifier: context.subject)
        }

        return participant
    }

    func updateProfile(input: ParticipantProfileInput) async throws -> Participant {
        let context = try authorizationService.checkIsParticipant()

        guard let participant = try await repository.findByIdentityProviderId(context.subject) else {
            throw ServerError.notFound(resource: "Participant", identifier: context.subject)
        }

        participant.firstName = input.firstName
        participant.lastName = input.lastName
        participant.email = context.email
        participant.gender = input.gender
        participant.dateOfBirth = input.dateOfBirth
        participant.region = input.region
        participant.language = input.language
        participant.phoneNumber = input.phoneNumber

        return try await repository.update(participant)
    }
}
