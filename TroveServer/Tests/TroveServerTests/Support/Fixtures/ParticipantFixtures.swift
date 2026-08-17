//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
@testable import TroveServer


enum ParticipantFixtures {
    static func profileBody(firstName: String = "Jane") -> [String: String] {
        [
            "firstName": firstName,
            "lastName": "Doe",
            "gender": "female",
            "dateOfBirth": "2000-01-15",
            "region": "US",
            "language": "en",
            "phoneNumber": "+1234567890"
        ]
    }

    @discardableResult
    static func createParticipant(
        on database: any Database,
        identityProviderId: String = "test-participant",
        id: UUID? = nil
    ) async throws -> Participant {
        let participant = Participant(
            identityProviderId: identityProviderId,
            firstName: "Jane",
            lastName: "Doe",
            email: "jane@example.com",
            gender: .female,
            dateOfBirth: DateComponents(calendar: .current, year: 2000, month: 1, day: 15).date!, // swiftlint:disable:this force_unwrapping
            region: "US",
            language: "en",
            phoneNumber: "+1234567890",
            id: id
        )
        try await participant.save(on: database)
        return participant
    }
}
