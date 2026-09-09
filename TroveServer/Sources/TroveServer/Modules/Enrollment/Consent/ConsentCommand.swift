//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Foundation


enum EnrollmentStateTag {
    static func make(enrollmentID: UUID, version: Int64) -> String {
        "\"enrollment-\(enrollmentID.uuidString)-v\(version)\""
    }

    static func parse(_ value: String, enrollmentID: UUID) throws -> Int64 {
        let prefix = "\"enrollment-\(enrollmentID.uuidString)-v"
        guard value.hasPrefix(prefix), value.hasSuffix("\"") else {
            throw ServerError.badRequest("If-Match must contain the strong state tag for this enrollment")
        }
        let digits = value.dropFirst(prefix.count).dropLast()
        guard !digits.isEmpty, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let version = Int64(digits), version > 0, String(version) == digits else {
            throw ServerError.badRequest("If-Match must contain a positive enrollment state version")
        }
        return version
    }
}


/// The semantic identity of one consent command, scoped to its authorized enrollment.
struct ConsentCommand: Sendable {
    let enrollmentID: UUID
    let commandID: UUID
    let expectedVersion: Int64
    let reviewedRevision: Int
    let proof: ConsentPresentationProof
    let responses: UserResponses
    let evidenceDigest: String

    init(
        enrollmentID: UUID,
        commandID: UUID,
        expectedVersion: Int64,
        reviewedRevision: Int,
        proof: ConsentPresentationProof,
        responses: UserResponses,
        evidence: Data
    ) {
        self.enrollmentID = enrollmentID
        self.commandID = commandID
        self.expectedVersion = expectedVersion
        self.reviewedRevision = reviewedRevision
        self.proof = proof
        self.responses = responses
        self.evidenceDigest = SHA256.hash(data: evidence).map { String(format: "%02x", $0) }.joined()
    }

    func validateNewSubmission(for enrollment: Enrollment) throws {
        guard enrollment.withdrawnAt == nil else {
            throw ServerError.conflict("Cannot submit consent for a withdrawn enrollment")
        }
        guard expectedVersion > 0, expectedVersion < Int64.max, enrollment.stateVersion == expectedVersion else {
            throw ServerError.preconditionFailed("Enrollment state changed before consent could be accepted")
        }
        guard reviewedRevision > 0, reviewedRevision >= enrollment.currentRevision else {
            throw ServerError.conflict("Consent cannot adopt an earlier enrollment revision")
        }
    }

    func replay(_ record: EnrollmentConsent) throws -> EnrollmentConsent {
        guard record.$enrollment.id == enrollmentID, record.commandID == commandID,
              expectedVersion > 0, expectedVersion < Int64.max,
              record.expectedEnrollmentVersion == expectedVersion,
              record.acceptedEnrollmentVersion == expectedVersion + 1,
              record.revision == reviewedRevision,
              !record.evidenceKey.isEmpty, record.evidenceDigest == evidenceDigest,
              record.presentationProof == proof, record.userResponses == responses else {
            throw ServerError.conflict("Consent command already exists with different or incomplete evidence")
        }
        return record
    }
}
