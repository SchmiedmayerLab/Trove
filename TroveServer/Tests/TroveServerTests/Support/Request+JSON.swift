//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TroveAPIServer
@testable import TroveServer
import Vapor
import VaporTesting


enum ConsentRequestFixtures {
    static func authorizationBody() -> Data? {
        let boundary = "AuthTestBoundary"
        let consentData: [String: Any] = [
            "toggles": [:] as [String: Bool],
            "selects": [:] as [String: String],
            "signatures": [:] as [String: Any]
        ]
        // Well-formed but nonexistent: the request must reach the enrollment authorization guard.
        let reference = Components.Schemas.ConsentPresentationReference(
            presentationId: "00000000-0000-0000-0000-000000000001", locale: "en-US", digest: String(repeating: "0", count: 64)
        )
        guard let jsonData = try? JSONSerialization.data(withJSONObject: consentData),
              let presentationData = try? JSONEncoder().encode(reference) else {
            return nil
        }
        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"reviewedRevision\"\r\n")
        body.append("Content-Type: application/json\r\n\r\n1\r\n--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"presentation\"\r\n")
        body.append("Content-Type: application/json\r\n\r\n")
        body.append(presentationData)
        body.append("\r\n--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"consentData\"\r\n")
        body.append("Content-Type: application/json\r\n\r\n")
        body.append(jsonData)
        body.append("\r\n--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"consentPDF\"; filename=\"consent.pdf\"\r\n")
        body.append("Content-Type: application/pdf\r\n\r\n%PDF-1.4 test")
        body.append("\r\n--\(boundary)--\r\n")
        return body
    }

    static func presentation(
        on app: Application,
        enrollmentID: String,
        token: String?,
        revision: Int? = nil
    ) async throws -> Components.Schemas.ConsentPresentationResponse {
        var result: Components.Schemas.ConsentPresentationResponse?
        let revisionQuery = revision.map { "&revision=\($0)" } ?? ""
        try await app.test(
            .GET,
            "\(apiBasePath)/participant/enrollments/\(enrollmentID)/consent-presentation?locale=en-US\(revisionQuery)",
            beforeRequest: { $0.bearerAuth(token) }
        ) { response in
            try #require(response.status == .ok)
            result = try response.content.decode(Components.Schemas.ConsentPresentationResponse.self)
        }
        return try #require(result)
    }
}


extension TestingHTTPRequest {
    mutating func bearerAuth(_ token: String?) {
        if let token {
            headers.bearerAuthorization = .init(token: token)
        }
    }

    mutating func encodeJSONBody(_ dictionary: [String: Any]) throws {
        self.headers.contentType = .json
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        self.body = .init(data: data)
    }

    mutating func encodeJSONBody(_ value: some Encodable) throws {
        self.headers.contentType = .json
        let data = try JSONEncoder().encode(value)
        self.body = .init(data: data)
    }

    mutating func encodeMultipartConsentBody(
        commandID: UUID,
        enrollmentETag: String,
        consentData: [String: Any],
        presentation: Components.Schemas.ConsentPresentationReference?,
        pdfData: Data = Data("%PDF-1.4 test".utf8),
        reviewedRevision: Int = 1
    ) throws {
        let boundary = "TestBoundary\(UUID().uuidString)"
        self.headers.replaceOrAdd(name: "Idempotency-Key", value: commandID.uuidString)
        self.headers.replaceOrAdd(name: "If-Match", value: enrollmentETag)
        self.headers.contentType = .init(type: "multipart", subType: "form-data", parameters: ["boundary": boundary])

        let jsonData = try JSONSerialization.data(withJSONObject: consentData)

        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"reviewedRevision\"\r\n")
        body.append("Content-Type: application/json\r\n\r\n")
        body.append("\(reviewedRevision)\r\n--\(boundary)\r\n")
        if let presentation {
            body.append("Content-Disposition: form-data; name=\"presentation\"\r\n")
            body.append("Content-Type: application/json\r\n\r\n")
            body.append(try JSONEncoder().encode(presentation))
            body.append("\r\n--\(boundary)\r\n")
        }
        body.append("Content-Disposition: form-data; name=\"consentData\"\r\n")
        body.append("Content-Type: application/json\r\n\r\n")
        body.append(jsonData)
        body.append("\r\n--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"consentPDF\"; filename=\"consent.pdf\"\r\n")
        body.append("Content-Type: application/pdf\r\n\r\n")
        body.append(pdfData)
        body.append("\r\n--\(boundary)--\r\n")

        self.body = .init(data: body)
    }
}


extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
