//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import OpenAPIRuntime
import TroveAPIClient


/// Retained only for its authenticated session; never regenerated while the outcome is uncertain.
struct PendingConsentCommand: Sendable, Equatable {
    static let maximumPDFBytes = 10_000_000

    let session: KeycloakSessionSnapshot
    let enrollmentID: String
    let commandID: UUID
    let reviewedRevision: Int
    let presentation: Components.Schemas.ConsentPresentationReference
    let enrollmentETag: String
    let expectedEnrollmentVersion: Int64
    let responses: Components.Schemas.UserResponses
    let pdf: Data

    func input() -> Operations.PostParticipantEnrollmentsEnrollmentIdConsents.Input {
        .init(
            path: .init(enrollmentId: enrollmentID),
            headers: .init(idempotencyKey: commandID.uuidString, ifMatch: enrollmentETag),
            body: .multipartForm([
                .presentation(.init(payload: .init(body: presentation))),
                .reviewedRevision(.init(payload: .init(body: reviewedRevision))),
                .consentData(.init(payload: .init(body: responses))),
                .consentPDF(.init(payload: .init(body: HTTPBody(pdf)), filename: "consent.pdf"))
            ])
        )
    }

    func validates(_ receipt: Components.Schemas.ConsentRecordResponse) -> Bool {
        UUID(uuidString: receipt.id) != nil
            && receipt.enrollmentId == enrollmentID && receipt.revision == reviewedRevision
            && receipt.presentation == presentation && receipt.userResponses == responses
            && expectedEnrollmentVersion > 0 && expectedEnrollmentVersion < Int64.max
            && receipt.acceptedEnrollmentVersion == expectedEnrollmentVersion + 1
    }
}
