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
    func postParticipantProfile(
        _ input: Operations.PostParticipantProfile.Input
    ) async throws -> Operations.PostParticipantProfile.Output {
        guard case .json(let schema) = input.body else {
            throw ServerError.jsonBodyRequired
        }
        let profileInput = try ParticipantProfileInput(schema)
        let participant = try await profileService.createProfile(input: profileInput)
        return .created(.init(body: .json(try .init(participant))))
    }

    func getParticipantProfile(
        _ input: Operations.GetParticipantProfile.Input
    ) async throws -> Operations.GetParticipantProfile.Output {
        let participant = try await profileService.getProfile()
        return .ok(.init(body: .json(try .init(participant))))
    }

    func putParticipantProfile(
        _ input: Operations.PutParticipantProfile.Input
    ) async throws -> Operations.PutParticipantProfile.Output {
        guard case .json(let schema) = input.body else {
            throw ServerError.jsonBodyRequired
        }
        let profileInput = try ParticipantProfileInput(schema)
        let participant = try await profileService.updateProfile(input: profileInput)
        return .ok(.init(body: .json(try .init(participant))))
    }
}
