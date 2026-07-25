//
// This source file is part of the StudyPlatform open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation


/// Mirrors `ConsentDocument.UserResponses` from SpeziConsent.
struct UserResponses: Codable, Sendable, Hashable {
    /// Responses to toggle elements, keyed by element ID.
    var toggles: [String: Bool]
    /// Responses to select elements, keyed by element ID.
    var selects: [String: String]
    /// Responses to signature elements, keyed by element ID.
    /// Stored as opaque JSON since `PKDrawing` is not available on Linux.
    var signatures: [String: SignatureData]

    init(
        toggles: [String: Bool] = [:],
        selects: [String: String] = [:],
        signatures: [String: SignatureData] = [:]
    ) {
        self.toggles = toggles
        self.selects = selects
        self.signatures = signatures
    }
}


/// Mirrors `ConsentDocument.SignatureData` from SpeziConsent.
struct SignatureData: Codable, Sendable, Hashable {
    var name: PersonNameComponents
    /// Opaque encoded signature (PKDrawing on iOS, String on macOS).
    var signature: String
    /// [width, height] in points.
    var size: [Double]

    init(name: PersonNameComponents = PersonNameComponents(), signature: String = "", size: [Double] = [0, 0]) {
        self.name = name
        self.signature = signature
        self.size = size
    }
}


final class EnrollmentConsent: Model, @unchecked Sendable {
    static let schema = "enrollment_consents"

    @ID(key: .id) var id: UUID?

    @Parent(key: "enrollment_id") var enrollment: Enrollment

    @Field(key: "revision") var revision: Int

    @Field(key: "user_responses") var userResponses: UserResponses

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        enrollmentId: UUID,
        revision: Int,
        userResponses: UserResponses,
        id: UUID? = nil
    ) {
        self.id = id
        self.$enrollment.id = enrollmentId
        self.revision = revision
        self.userResponses = userResponses
    }
}
