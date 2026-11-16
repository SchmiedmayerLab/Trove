//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
import TroveAPIClient
@testable import TroveCLI


private actor RecordingTransport: ClientTransport {
    let status: Int
    let headers: HTTPFields
    let bytes: Data
    private(set) var requests: [HTTPRequest] = []

    init(
        status: Int = 200,
        headers: HTTPFields = [
            .contentType: "application/octet-stream", .cacheControl: "no-store", .contentDisposition: "attachment; filename=ignored.csv"
        ],
        originalContentType: String? = "text/csv",
        bytes: Data = Data("time,value\n1,2\n".utf8)
    ) throws {
        self.status = status
        var headers = headers
        headers[try #require(HTTPField.Name("X-Recording-Content-Type"))] = originalContentType
        self.headers = headers
        self.bytes = bytes
    }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        requests.append(request)
        return (HTTPResponse(status: .init(code: status), headerFields: headers), HTTPBody(bytes))
    }
}


struct StudyRecordingClientTests {
    private func client(_ transport: RecordingTransport) throws -> AuthoringClient {
        AuthoringClient(
            serverURL: try #require(URL(string: "https://research.example/api/v0")),
            token: "synthetic-test-credential",
            transport: transport
        )
    }

    @Test(arguments: [Components.Schemas.StudyDataVersions.current, .history])
    func requestsExactStudyGrantAndView(versions: Components.Schemas.StudyDataVersions) async throws {
        let study = UUID()
        let grant = UUID()
        let transport = try RecordingTransport()
        let body = try await client(transport).getStudyRecording(study, grant: grant, versions: versions)
        #expect(try await Data(collecting: body, upTo: 1024) == Data("time,value\n1,2\n".utf8))
        let requests = await transport.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.path == "/studies/\(study.uuidString)/data/recordings/\(grant.uuidString)?versions=\(versions.rawValue)")
        #expect(request.headerFields[.authorization] == "Bearer synthetic-test-credential")
        #expect(request.headerFields[.acceptEncoding] == "identity")
        #expect(request.headerFields[.ifMatch] == nil)
        #expect(request.headerFields[try #require(HTTPField.Name("Trove-Delegation-ID"))] == nil)
    }

    @Test(arguments: [302, 401, 403, 404, 409, 503])
    func refusesErrorResponsesWithoutRetry(status: Int) async throws {
        let transport = try RecordingTransport(status: status)
        await #expect(throws: CLIError.httpStatus(status)) {
            _ = try await client(transport).getStudyRecording(UUID(), grant: UUID(), versions: .current)
        }
        #expect(await transport.requests.count == 1)
    }

    @Test(arguments: ["gzip", "br", "zstd", "identity, gzip"])
    func refusesEncodedRepresentationsBeforeReturningBody(encoding: String) async throws {
        let transport = try RecordingTransport(headers: [
            .contentType: "application/octet-stream", .cacheControl: "no-store", .contentDisposition: "attachment", .contentEncoding: encoding
        ])
        await #expect(throws: CLIError.requestFailed) {
            _ = try await client(transport).getStudyRecording(UUID(), grant: UUID(), versions: .current)
        }
    }

    @Test(arguments: ["identity", "IDENTITY"])
    func acceptsExplicitIdentityEncoding(encoding: String) async throws {
        let transport = try RecordingTransport(headers: [
            .contentType: "application/octet-stream", .cacheControl: "no-store", .contentDisposition: "attachment", .contentEncoding: encoding
        ])
        let body = try await client(transport).getStudyRecording(UUID(), grant: UUID(), versions: .current)
        #expect(try await Data(collecting: body, upTo: 1024) == Data("time,value\n1,2\n".utf8))
    }

    @Test(arguments: Operations.GetStudyRecording.Output.Ok.Headers.XRecordingContentTypePayload.allCases)
    func preservesOriginalBytesAcrossRegisteredMedia(
        media: Operations.GetStudyRecording.Output.Ok.Headers.XRecordingContentTypePayload
    ) async throws {
        let bytes = media == .applicationOctetStream ? Data([0, 255, 128, 13, 10]) : Data("{\"exact\":9007199254740993.123456789}\n".utf8)
        let transport = try RecordingTransport(originalContentType: media.rawValue, bytes: bytes)
        let body = try await client(transport).getStudyRecording(UUID(), grant: UUID(), versions: .current)
        #expect(try await Data(collecting: body, upTo: 1024) == bytes)
        let request = try #require(await transport.requests.first)
        #expect(request.headerFields[.accept]?.contains("application/octet-stream") == true)
    }

    @Test(arguments: [String?.none, "text/html", "application/fhir+json; fhirVersion=5.0"])
    func rejectsMissingOrUnregisteredOriginalMedia(media: String?) async throws {
        let transport = try RecordingTransport(originalContentType: media)
        await #expect(throws: CLIError.requestFailed) {
            _ = try await client(transport).getStudyRecording(UUID(), grant: UUID(), versions: .current)
        }
    }

    @Test
    func requiresContractHeaders() async throws {
        let transport = try RecordingTransport(headers: [.contentType: "application/octet-stream"])
        await #expect(throws: CLIError.requestFailed) {
            _ = try await client(transport).getStudyRecording(UUID(), grant: UUID(), versions: .current)
        }
    }
}
