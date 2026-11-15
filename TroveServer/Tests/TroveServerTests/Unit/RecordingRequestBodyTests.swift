//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import HTTPTypes
import OpenAPIRuntime
import Testing
import TroveAPIServer
@testable import TroveServer


struct RecordingRequestBodyTests {
    @Test(arguments: [nil, "", "0", "-1", "+1", "1 1", "1.0", "2147483648", "9223372036854775808"] as [String?])
    func invalidLengthsAreRejectedWithoutReadingBytes(length: String?) async throws {
        let request = HTTPRequest(method: .put, scheme: "https", authority: "example.test", path: "/")
        var fields = request
        fields.headerFields[.contentLength] = length
        await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
            await #expect {
                try await ClinicalRequestBodyMiddleware().intercept(
                    fields, body: Self.unreadBody(), metadata: .init(), operationID: Operations.UploadParticipantRecordingTransfer.id
                ) { _, _, _ in
                    Issue.record("Invalid upload reached its handler")
                    return (.init(status: .ok), nil)
                }
            } throws: { error in
                (error as? TroveServer.ServerError)?.status.code == 400
            }
        }
    }

    @Test(arguments: ["100663297", " 100663297 "])
    func validMetadataPassesAnUnconsumedSingleUseStreamToTheHandler(length: String) async throws {
        var request = HTTPRequest(method: .put, scheme: "https", authority: "example.test", path: "/")
        request.headerFields[.contentLength] = length
        _ = try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
            try await ClinicalRequestBodyMiddleware().intercept(
                request, body: Self.unreadBody(), metadata: .init(), operationID: Operations.UploadParticipantRecordingTransfer.id
            ) { _, body, _ in
                #expect(body?.length == .known(100_663_297))
                #expect(body?.iterationBehavior == .single)
                return (.init(status: .ok), nil)
            }
        }
    }
}


extension RecordingRequestBodyTests {
    private static func unreadBody() -> HTTPBody {
        HTTPBody(AsyncThrowingStream<HTTPBody.ByteChunk, any Error>(unfolding: {
            Issue.record("Middleware consumed recording bytes before the handler")
            return nil
        }), length: .unknown)
    }
}
