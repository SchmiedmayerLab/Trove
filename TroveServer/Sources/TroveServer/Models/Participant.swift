//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation


/// Describes the self-identified gender identity.
///
/// Originally defined in Grove's account module.
enum GenderIdentity: String, Sendable, CaseIterable, Identifiable, Hashable, Codable {
    /// Self-identify as female.
    case female
    /// Self-identify as male.
    case male
    /// Self-identify as transgender.
    case transgender
    /// Self-identify as non-binary.
    case nonBinary
    /// Prefer not to state the self-identified gender.
    case preferNotToState

    var id: RawValue { rawValue }
}


final class Participant: Model, @unchecked Sendable {
    static let schema = "participants"

    @ID(key: .id) var id: UUID?

    @Field(key: "identity_provider_issuer") var identityProviderIssuer: String

    @Field(key: "identity_provider_id") var identityProviderId: String

    @Field(key: "first_name") var firstName: String

    @Field(key: "last_name") var lastName: String

    @Field(key: "email") var email: String

    @Field(key: "gender") var gender: GenderIdentity

    @Field(key: "date_of_birth") var dateOfBirth: Date

    @Field(key: "region") var region: String

    @Field(key: "language") var language: String

    @Field(key: "phone_number") var phoneNumber: String

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    @Children(for: \.$participant) var enrollments: [Enrollment]

    init() {}

    init(
        identityProviderIssuer: String,
        identityProviderId: String,
        firstName: String,
        lastName: String,
        email: String,
        gender: GenderIdentity,
        dateOfBirth: Date,
        region: String,
        language: String,
        phoneNumber: String,
        id: UUID? = nil
    ) {
        self.id = id
        self.identityProviderIssuer = identityProviderIssuer
        self.identityProviderId = identityProviderId
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self.gender = gender
        self.dateOfBirth = dateOfBirth
        self.region = region
        self.language = language
        self.phoneNumber = phoneNumber
    }
}
