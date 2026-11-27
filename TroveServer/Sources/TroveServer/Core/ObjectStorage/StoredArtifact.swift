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
struct StudyArtifactScope: Sendable, Equatable {
    let studyID: UUID
    var groupID: UUID?
}


struct ArtifactReference: Sendable {
    enum Purpose: String, Codable, Sendable {
        case consent, publication, recording, taskResponse

        var contentType: String {
            switch self {
            case .taskResponse: "application/fhir+json"
            case .consent: "application/pdf"
            case .publication: "application/zip"
            case .recording: "application/octet-stream"
            }
        }
        var maximumBytes: Int {
            switch self {
            case .taskResponse: FHIRValidationClient.maximumBytes
            case .consent: 10 * 1024 * 1024
            case .publication: 50 * 1024 * 1024
            case .recording: Int(Int32.max)
            }
        }
        var directory: String {
            switch self {
            case .taskResponse: "task-responses"
            case .consent: "consents"
            case .publication: "publications"
            case .recording: "recordings"
            }
        }
    }

    let id: UUID
    let ownerID: UUID
    let purpose: Purpose
    let digest: String
    let byteCount: Int
    let scope: ArtifactScope

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
    @OptionalField(key: "study_id") var studyID: UUID?
    @OptionalField(key: "group_id") var groupID: UUID?
    @OptionalField(key: "participant_id") var participantID: UUID?
    @OptionalField(key: "source_binding_id") var sourceBindingID: UUID?
    @Field(key: "state") var state: State
    @Field(key: "expires_at") var expiresAt: Date
    @OptionalField(key: "cleanup_after") var cleanupAfter: Date?
    @OptionalField(key: "last_deleted_at") var lastDeletedAt: Date?

    init() {}

    init(reference: ArtifactReference, expiresAt: Date) {
        id = reference.id
        ownerID = reference.ownerID
        purpose = reference.purpose
        digest = reference.digest
        byteCount = reference.byteCount
        switch reference.scope {
        case .study(let scope):
            studyID = scope.studyID
            groupID = scope.groupID
        case .participantSource(let scope):
            participantID = scope.participantID
            sourceBindingID = scope.sourceBindingID
        }
        state = .staging
        self.expiresAt = expiresAt
        cleanupAfter = expiresAt
    }

    func reference() throws -> ArtifactReference {
        let scope: ArtifactScope
        switch (purpose, studyID, groupID, participantID, sourceBindingID) {
        case let (.consent, study?, group, nil, nil), let (.publication, study?, group, nil, nil), let (.taskResponse, study?, group, nil, nil):
            scope = .study(.init(studyID: study, groupID: group))
        case let (.recording, nil, nil, participant?, source?) where ownerID == participant:
            scope = .participantSource(.init(participantID: participant, sourceBindingID: source))
        default:
            throw ServerError.internalServerError("Invalid artifact ownership")
        }
        return .init(id: try requireID(), ownerID: ownerID, purpose: purpose, digest: digest, byteCount: byteCount, scope: scope)
    }
}
