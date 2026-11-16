//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation
import TroveAPITypes


/// Mirrors `ConsentDocument.UserResponses` from GroveConsent.
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


/// Mirrors `ConsentDocument.SignatureData` from GroveConsent.
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


/// The immutable localized document identity accepted with a consent record.
struct ConsentPresentationProof: Codable, Sendable, Hashable {
    let presentationID: UUID
    let locale: String
    let digest: String
}


final class EnrollmentConsent: Model, @unchecked Sendable {
    static let schema = "enrollment_consents"

    @ID(key: .id) var id: UUID?

    @Parent(key: "enrollment_id") var enrollment: Enrollment

    @Field(key: "revision") var revision: Int

    @Field(key: "user_responses") var userResponses: UserResponses

    @Field(key: "evidence_key") var evidenceKey: String

    @Field(key: "evidence_digest") var evidenceDigest: String

    @Field(key: "artifact_id") var artifactID: UUID

    @Field(key: "presentation_proof") var presentationProof: ConsentPresentationProof

    @Field(key: "command_id") var commandID: UUID

    @Field(key: "expected_enrollment_version") var expectedEnrollmentVersion: Int64

    /// Version at acceptance, never replaced with the enrollment's current version on replay.
    @Field(key: "accepted_enrollment_version") var acceptedEnrollmentVersion: Int64

    @OptionalField(key: "collection_scope") var collectionScope: AcceptedCollectionScope?

    /// Set inside the acceptance transaction, before resolving calendar-relative measurement bounds.
    @Timestamp(key: "created_at", on: .none) var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        enrollmentId: UUID,
        revision: Int,
        userResponses: UserResponses,
        evidenceKey: String,
        evidenceDigest: String,
        artifactID: UUID,
        presentationProof: ConsentPresentationProof,
        commandID: UUID,
        expectedEnrollmentVersion: Int64,
        acceptedEnrollmentVersion: Int64,
        id: UUID? = nil
    ) {
        self.id = id
        self.createdAt = Date()
        self.collectionScope = nil
        self.$enrollment.id = enrollmentId
        self.revision = revision
        self.userResponses = userResponses
        self.evidenceKey = evidenceKey
        self.evidenceDigest = evidenceDigest
        self.artifactID = artifactID
        self.presentationProof = presentationProof
        self.commandID = commandID
        self.expectedEnrollmentVersion = expectedEnrollmentVersion
        self.acceptedEnrollmentVersion = acceptedEnrollmentVersion
    }
}


extension EnrollmentConsent {
    func resolveCollectionScope(from publication: PublishedStudy, before end: Date? = nil, at now: Date = .now) throws {
        let codec = TroveDateTranscoder()
        let acceptedAt = try codec.decode(codec.encode(now))
        // Target validation may suspend after the initial enrollment check. Bind the
        // deadline to the exact retained acceptance instant, before changing any state.
        guard end.map({ acceptedAt < $0 }) ?? true else {
            throw ServerError.conflict("Cannot submit consent for an ended enrollment")
        }
        let requirements = try publication.collectionPolicy.validatedRequirements(studyID: publication.$study.id, revision: revision)
        collectionScope = try AcceptedCollectionScope(requirements: requirements, acceptedAt: acceptedAt)
        createdAt = acceptedAt
    }
}
