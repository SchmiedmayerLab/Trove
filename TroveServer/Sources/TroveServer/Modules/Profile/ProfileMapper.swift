//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import TroveAPIServer


private let dateOnlyFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.isLenient = false
    return formatter
}()


struct ParticipantProfileInput: Sendable {
    var firstName: String
    var lastName: String
    var gender: GenderIdentity
    var dateOfBirth: Date
    var region: String
    var language: String
    var phoneNumber: String

    init(_ schema: Components.Schemas.ParticipantProfileInput) throws {
        self.firstName = schema.firstName
        self.lastName = schema.lastName
        self.gender = switch schema.gender {
        case .female: .female
        case .male: .male
        case .transgender: .transgender
        case .nonBinary: .nonBinary
        case .preferNotToState: .preferNotToState
        }
        guard schema.dateOfBirth.utf8.count == 10,
              let dateOfBirth = dateOnlyFormatter.date(from: schema.dateOfBirth),
              dateOnlyFormatter.string(from: dateOfBirth) == schema.dateOfBirth else {
            throw ServerError.badRequest("Invalid date format, expected yyyy-MM-dd")
        }
        self.dateOfBirth = dateOfBirth
        self.region = schema.region
        self.language = schema.language
        self.phoneNumber = schema.phoneNumber
    }
}


extension Components.Schemas.ParticipantProfile {
    init(_ model: Participant) throws {
        let gender: Components.Schemas.GenderIdentity = switch model.gender {
        case .female: .female
        case .male: .male
        case .transgender: .transgender
        case .nonBinary: .nonBinary
        case .preferNotToState: .preferNotToState
        }
        self.init(
            id: try model.requireId().uuidString,
            firstName: model.firstName,
            lastName: model.lastName,
            email: model.email,
            gender: gender,
            dateOfBirth: dateOnlyFormatter.string(from: model.dateOfBirth),
            region: model.region,
            language: model.language,
            phoneNumber: model.phoneNumber
        )
    }
}
