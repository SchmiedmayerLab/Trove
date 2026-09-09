//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Fluent
import Foundation


/// Consent and publication artifacts always belong to one study, even before acceptance.
struct StudyArtifactScope: Sendable {
    let studyID: UUID
    var groupID: UUID?
}


struct ArtifactReference: Sendable {
    enum Purpose: String, Codable, Sendable {
        case consent, publication

        var contentType: String { self == .consent ? "application/pdf" : "application/zip" }
        var maximumBytes: Int { (self == .consent ? 10 : 50) * 1024 * 1024 }
        var directory: String { self == .consent ? "consents" : "publications" }
    }

    let id: UUID
    let ownerID: UUID
    let purpose: Purpose
    let digest: String
    let byteCount: Int

    var key: String { "artifacts/\(purpose.directory)/\(ownerID)/\(id)" }
}


/// Rows outlive interrupted writers and domain deletion. Retention is not inferred from object existence.
final class StoredArtifact: Model, @unchecked Sendable {
    enum State: String, Codable, Sendable {
        case staging, ready, retained, discarding
    }

    static let schema = "stored_artifacts"

    @ID(key: .id) var id: UUID?
    @Field(key: "owner_id") var ownerID: UUID
    @Field(key: "purpose") var purpose: ArtifactReference.Purpose
    @Field(key: "digest") var digest: String
    @Field(key: "byte_count") var byteCount: Int
    @Field(key: "study_id") var studyID: UUID
    @OptionalField(key: "group_id") var groupID: UUID?
    @Field(key: "state") var state: State
    @Field(key: "expires_at") var expiresAt: Date
    @OptionalField(key: "cleanup_after") var cleanupAfter: Date?
    @OptionalField(key: "last_deleted_at") var lastDeletedAt: Date?

    init() {}

    init(reference: ArtifactReference, scope: StudyArtifactScope, expiresAt: Date) {
        id = reference.id
        ownerID = reference.ownerID
        purpose = reference.purpose
        digest = reference.digest
        byteCount = reference.byteCount
        studyID = scope.studyID
        groupID = scope.groupID
        state = .staging
        self.expiresAt = expiresAt
        cleanupAfter = expiresAt
    }

    func reference() throws -> ArtifactReference {
        .init(id: try requireID(), ownerID: ownerID, purpose: purpose, digest: digest, byteCount: byteCount)
    }
}
