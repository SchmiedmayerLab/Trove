//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Vapor
import VaporTesting


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

    mutating func encodeMultipartConsentBody(consentData: [String: Any], pdfData: Data = Data("%PDF-1.4 test".utf8)) throws {
        let boundary = "TestBoundary\(UUID().uuidString)"
        self.headers.contentType = .init(type: "multipart", subType: "form-data", parameters: ["boundary": boundary])

        let jsonData = try JSONSerialization.data(withJSONObject: consentData)

        var body = Data()
        body.append("--\(boundary)\r\n")
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
