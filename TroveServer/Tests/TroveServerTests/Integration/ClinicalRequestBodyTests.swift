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
import VaporTesting


struct ClinicalRequestBodyTests {
    @Test(arguments: ["", "not-base64", "e30", "e30=\n", "e31="])
    func malformedAndNoncanonicalBase64IsRejected(encoded: String) async throws {
        try await TestApp.withApp(token: .participant(subject: "body-test")) { app, token in
            try await app.test(.POST, "\(apiBasePath)/participant/sources/\(UUID())/events", beforeRequest: {
                $0.bearerAuth(token)
                try $0.encodeJSONBody(Self.body(encoded))
            }) { #expect($0.status == .badRequest) }
        }
    }

    @Test
    func decodedOverflowReturns413BeforeSourceLookupOrValidation() async throws {
        let encoded = Data(repeating: 1, count: FHIRValidationClient.maximumBytes + 1).base64EncodedString()
        try await TestApp.withApp(token: .participant(subject: "body-test")) { app, token in
            try await app.test(.POST, "\(apiBasePath)/participant/sources/\(UUID())/events", beforeRequest: {
                $0.bearerAuth(token)
                try $0.encodeJSONBody(Self.body(encoded))
            }) { #expect($0.status == .payloadTooLarge) }
        }
    }

    @Test(arguments: [
        (TestApp.Token.none, HTTPStatus.unauthorized), (.researcher(), .forbidden), (.participant(subject: "body-test"), .payloadTooLarge)
    ])
    func authenticationPrecedesEnvelopeCollection(identity: TestApp.Token, status: HTTPStatus) async throws {
        try await TestApp.withApp(token: identity) { app, token in
            try await app.test(.POST, "\(apiBasePath)/participant/sources/\(UUID())/events", beforeRequest: {
                $0.bearerAuth(token)
                $0.headers.contentType = .json
                $0.body = .init(data: Data(repeating: 32, count: 6 * 1024 * 1024 + 1))
            }) { #expect($0.status == status) }
        }
    }
}


extension ClinicalRequestBodyTests {
    private static func body(_ encoded: String) -> Components.Schemas.EventSubmission {
        .init(eventBase64: encoded, targets: [.init(consentId: UUID().uuidString, outputFullUrls: ["urn:uuid:point"])])
    }
}
