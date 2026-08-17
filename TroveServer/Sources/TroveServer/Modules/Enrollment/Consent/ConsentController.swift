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
        guard case .multipartForm(let multipartBody) = input.body else {
            throw ServerError.badRequest("Request body must be multipart/form-data")
        }

        var userResponses: UserResponses?
        var pdfData: Data?

        for try await part in multipartBody {
            switch part {
            case .consentData(let payload):
                userResponses = UserResponses(payload.payload.body)
            case .consentPDF(let payload):
                pdfData = try await Data(collecting: payload.payload.body, upTo: 10_000_000)
            case .undocumented:
                break
            }
        }

        guard let userResponses, let pdfData else {
            throw ServerError.badRequest("Request must include both consentData and consentPDF parts")
        }

        let record = try await consentService.createConsent(
            enrollmentId: enrollmentId,
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
        let pdfKey = try await consentService.getConsentPdfKey(enrollmentId: enrollmentId, consentId: consentId)
        let data = try await objectStorageService.download(key: pdfKey)
        return .ok(.init(
            headers: .init(contentDisposition: "attachment; filename=\"consent-\(consentId).pdf\""),
            body: .pdf(HTTPBody(data))
        ))
    }
}
