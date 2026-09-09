//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Fluent
import Foundation
import Testing
@testable import TroveServer


/// Synthetic retained records for schema/authorization tests, not evidence of successful upload or consent review.
/// Tests exercising acceptance must call the production publication and consent services instead.
enum RetainedRecordFixtures {
    static func artifact(
        on database: any Database,
        ownerID: UUID,
        studyID: UUID,
        purpose: ArtifactReference.Purpose,
        bytes: Data = Data("Synthetic retained fixture".utf8)
    ) async throws -> ArtifactReference {
        let reference = ArtifactReference(
            id: UUID(),
            ownerID: ownerID,
            purpose: purpose,
            digest: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            byteCount: bytes.count
        )
        let record = StoredArtifact(reference: reference, scope: .init(studyID: studyID), expiresAt: Date())
        record.state = .retained
        record.cleanupAfter = nil
        try await record.save(on: database)
        return reference
    }

    /// Returns an unsaved consent so constraint tests can attempt invalid inserts explicitly.
    static func consent(
        on database: any Database,
        enrollmentID: UUID,
        revision: Int = 1,
        responses: UserResponses = .init(),
        commandID: UUID = UUID(),
        bytes: Data = Data("%PDF-1.4 Synthetic retained consent".utf8)
    ) async throws -> EnrollmentConsent {
        let enrollment = try #require(try await Enrollment.find(enrollmentID, on: database))
        let reference = try await artifact(on: database, ownerID: enrollmentID, studyID: enrollment.$study.id, purpose: .consent, bytes: bytes)
        return EnrollmentConsent(
            enrollmentId: enrollmentID,
            revision: revision,
            userResponses: responses,
            evidenceKey: reference.key,
            evidenceDigest: reference.digest,
            artifactID: reference.id,
            presentationProof: .init(
                presentationID: UUID(),
                locale: "en-US",
                digest: SHA256.hash(data: Data(PublishedStudyFixtures.requiredConsentMarkdown.utf8)).map { String(format: "%02x", $0) }.joined()
            ),
            commandID: commandID,
            expectedEnrollmentVersion: 1,
            acceptedEnrollmentVersion: 2
        )
    }
}
