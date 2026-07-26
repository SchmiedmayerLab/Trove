//
// This source file is part of the StudyPlatform-iOS open source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SpeziAccount
import StudyPlatformAPIClient


enum ProfileMapping {
    static func accountDetails(from profile: StudyPlatform.Profile) -> AccountDetails {
        var details = AccountDetails()
        var name = PersonNameComponents()
        name.givenName = profile.firstName
        name.familyName = profile.lastName
        details.name = name
        details.genderIdentity = SpeziAccount.GenderIdentity(rawValue: profile.gender.rawValue)
        if let dob = Date(iso8601DateString: profile.dateOfBirth) { details.dateOfBirth = dob }
        details.region = profile.region
        details.language = profile.language
        details.phoneNumber = profile.phoneNumber
        return details
    }

    static func profileInput(from details: AccountDetails) -> StudyPlatform.ProfileInput {
        StudyPlatform.ProfileInput(
            firstName: details.name?.givenName ?? "",
            lastName: details.name?.familyName ?? "",
            gender: details.genderIdentity.flatMap { StudyPlatform.GenderIdentity(rawValue: $0.rawValue) } ?? .preferNotToState,
            dateOfBirth: details.dateOfBirth?.iso8601DateString ?? "",
            region: details.region ?? "",
            language: details.language ?? "",
            phoneNumber: details.phoneNumber ?? ""
        )
    }
}
