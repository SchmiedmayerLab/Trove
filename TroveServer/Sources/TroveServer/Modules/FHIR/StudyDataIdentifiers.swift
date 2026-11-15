//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import ModelsR4


/// Study UUIDs define persistent namespaces independently of a request host, account,
/// installation or source-key epoch. Enrollment UUIDs are stable within their study.
struct StudyDataIdentifiers {
    let studyID: UUID

    private var root: String { "urn:trove:study:" + studyID.uuidString.lowercased() }

    func enrollment(id: UUID, revision: Int) throws -> StudyEnrollment {
        guard revision > 0 else { throw ServerError.unexpectedError }
        return try .init(
            study: BusinessIdentifier(system: IdentifierSystem("urn:trove:studies"), value: studyID.uuidString.lowercased()),
            protocolURL: FHIRPrimitive(Canonical(stringLiteral: root + ":protocol")),
            protocolVersion: String(revision),
            enrollment: BusinessIdentifier(system: IdentifierSystem(root + ":enrollments"), value: id.uuidString.lowercased())
        )
    }

    func context(enrollmentID: UUID, endsAt: Date?, recordedAt: Date) throws -> StudyPointExport.Context {
        try .init(
            subject: BusinessIdentifier(system: IdentifierSystem(root + ":participants"), value: enrollmentID.uuidString.lowercased()),
            exportSystem: IdentifierSystem(root + ":exports"),
            grantSystem: IdentifierSystem(root + ":grants"),
            receiver: BusinessIdentifier(system: IdentifierSystem(root + ":services"), value: "study-export"),
            recordedAt: recordedAt,
            enrollmentEndsAt: endsAt
        )
    }
}
