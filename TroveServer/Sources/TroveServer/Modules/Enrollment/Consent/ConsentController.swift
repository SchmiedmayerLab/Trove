//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import OpenAPIRuntime
import TroveAPIServer


extension Controller {
    func getParticipantEnrollmentsEnrollmentIdConsentPresentation(
        _ input: Operations.GetParticipantEnrollmentsEnrollmentIdConsentPresentation.Input
    ) async throws -> Operations.GetParticipantEnrollmentsEnrollmentIdConsentPresentation.Output {
        let enrollmentID = try input.path.enrollmentId.requireId()
        let snapshot = try await consentService.getPresentation(
            enrollmentId: enrollmentID, locale: input.query.locale, revision: input.query.revision
        )
        let presentation = snapshot.presentation
        return .ok(.init(body: .json(.init(
            presentation: .init(presentationId: presentation.presentationID.uuidString, locale: presentation.locale, digest: presentation.digest),
            revision: presentation.revision,
            markdown: presentation.markdown,
            enrollmentStateVersion: snapshot.enrollmentVersion,
            enrollmentETag: EnrollmentStateTag.make(enrollmentID: enrollmentID, version: snapshot.enrollmentVersion)
        ))))
    }

    func getParticipantEnrollmentsEnrollmentIdConsents(
        _ input: Operations.GetParticipantEnrollmentsEnrollmentIdConsents.Input
    ) async throws -> Operations.GetParticipantEnrollmentsEnrollmentIdConsents.Output {
        let enrollmentId = try input.path.enrollmentId.requireId()
        let records = try await consentService.listConsents(enrollmentId: enrollmentId)
        return .ok(.init(body: .json(try records.map { try .init($0) })))
    }

    func postParticipantEnrollmentsEnrollmentIdConsents(
        _ input: Operations.PostParticipantEnrollmentsEnrollmentIdConsents.Input
    ) async throws -> Operations.PostParticipantEnrollmentsEnrollmentIdConsents.Output {
        let enrollmentId = try input.path.enrollmentId.requireId()
        let commandID = try input.headers.idempotencyKey.requireId()
        let expectedVersion = try EnrollmentStateTag.parse(input.headers.ifMatch, enrollmentID: enrollmentId)
        guard case .multipartForm(let multipartBody) = input.body else {
            throw ServerError.badRequest("Request body must be multipart/form-data")
        }

        var userResponses: UserResponses?
        var pdfData: Data?
        var reviewedRevision: Int?
        var presentationReference: Components.Schemas.ConsentPresentationReference?

        do {
            for try await part in multipartBody {
                switch part {
                case .presentation(let payload):
                    presentationReference = payload.payload.body
                case .reviewedRevision(let payload):
                    reviewedRevision = payload.payload.body
                case .consentData(let payload):
                    userResponses = UserResponses(payload.payload.body)
                case .consentPDF(let payload):
                    pdfData = try await Data(collecting: payload.payload.body, upTo: 10_000_000)
                case .undocumented:
                    break
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Only request-body consumption is inside this boundary. Storage and
            // domain failures below must retain their server error classification.
            throw ServerError.invalidRequestBody
        }

        guard let userResponses, let pdfData, let reviewedRevision, reviewedRevision > 0, let presentationReference else {
            throw ServerError.badRequest("Request must include consentData, consentPDF, presentation, and a positive reviewedRevision")
        }

        let record = try await consentService.createConsent(
            enrollmentId: enrollmentId,
            commandID: commandID,
            expectedEnrollmentVersion: expectedVersion,
            reviewedRevision: reviewedRevision,
            presentationProof: .init(
                presentationID: try presentationReference.presentationId.requireId(),
                locale: presentationReference.locale,
                digest: presentationReference.digest
            ),
            userResponses: userResponses,
            pdfData: pdfData
        )
        return .created(.init(body: .json(try .init(record))))
    }

    func getParticipantEnrollmentsEnrollmentIdConsentsConsentIdPdf(
        _ input: Operations.GetParticipantEnrollmentsEnrollmentIdConsentsConsentIdPdf.Input
    ) async throws -> Operations.GetParticipantEnrollmentsEnrollmentIdConsentsConsentIdPdf.Output {
        let enrollmentId = try input.path.enrollmentId.requireId()
        let consentId = try input.path.consentId.requireId()
        let data = try await consentService.getConsentPDF(enrollmentId: enrollmentId, consentId: consentId)
        return .ok(.init(
            headers: .init(contentDisposition: "attachment; filename=\"consent-\(consentId).pdf\""),
            body: .pdf(HTTPBody(data))
        ))
    }
}
