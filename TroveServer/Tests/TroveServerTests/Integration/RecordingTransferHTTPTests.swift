//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SQLKit
import Testing
import TroveAPIClient
@testable import TroveServer
import VaporTesting


/// Generated-client requests pass through the real router, JWT middleware, source proof and transfer service.
struct RecordingTransferHTTPTests {
    static let bytes = Data("synthetic recording transport".utf8)

    @Test(arguments: [false, true])
    func generatedClientsRegisterUploadAndRecoverWithoutDuplicatingObjects(loseResponse: Bool) async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant")) { app, token in
            let fixture = try await Self.prepare(on: app)
            let transferID = UUID()
            let declaration = Self.declaration(fixture)
            let transport = ReceiverClientTransport(application: app, token: token, loseRecordingResponse: loseResponse)
            let client = try TroveAPIClient.Client(serverURL: Servers.Server1.url(), configuration: .trove, transport: transport)
            let registered = try await Self.register(client, fixture: fixture, id: transferID, declaration: declaration)
            let commitment = try RecordingTransferCommitment(declaration)
            try commitment.verify(registered, sourceID: fixture.source.id, transferID: transferID)
            #expect(registered.sourceId == fixture.source.id.uuidString.lowercased())
            #expect(registered.storedSHA256 == declaration.content.storedSHA256)
            let replay = try await Self.register(client, fixture: fixture, id: transferID, declaration: declaration)
            #expect(registered == replay)
            try await Self.send(client, fixture: fixture, id: transferID, expectResponseLoss: loseResponse)
            let receipt = try await Self.lookup(client, fixture: fixture, id: transferID)
            try commitment.verify(receipt, sourceID: fixture.source.id, transferID: transferID)
            #expect(receipt.transferId == registered.transferId)
            #expect(receipt.declarationSHA256 == registered.declarationSHA256)
            #expect(receipt.storedByteCount == Int64(Self.bytes.count) && receipt.storedSHA256 == ArtifactStore.digest(Self.bytes))
            #expect(receipt.expiresAt > receipt.verifiedAt)
            #expect(await transport.recordingBodies == [Self.bytes])
            try await Self.expectRows(transfers: 1, attempts: 1, receipts: 1, on: app)
            try await ClinicalEventStoreTests.expectRows(events: 0, nodes: 0, facts: 0, grants: 0, on: app.db)
        }
    }

    @Test
    func receiptLookupAfterWithdrawalAndRevocationDoesNotRestoreUploadAuthority() async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant")) { app, token in
            let fixture = try await Self.prepare(on: app), id = UUID()
            let client = try Self.client(app, token: token)
            _ = try await Self.register(client, fixture: fixture, id: id, declaration: Self.declaration(fixture))
            try await Self.send(client, fixture: fixture, id: id, expectResponseLoss: false)
            let first = try await Self.lookup(client, fixture: fixture, id: id)
            try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
                _ = try await app.grove[ParticipantEnrollmentService.self].withdraw(enrollmentId: fixture.enrollmentIDs[0])
                _ = try await app.grove[SourceBindingService.self].revoke(id: fixture.source.id)
            }
            #expect(try await Self.lookup(client, fixture: fixture, id: id) == first)
            let rejected = try await client.uploadParticipantRecordingTransfer(.init(
                path: .init(sourceId: fixture.source.id.uuidString, transferId: id.uuidString),
                headers: .init(
                    troveSourceInstallationID: fixture.installationID.uuidString,
                    troveSourceCredential: SourceBindingFixture.credentialBase64(fixture.installationID)
                ),
                body: .binary(.init(Self.bytes))
            ))
            #expect(rejected.isConflict)
            try await Self.expectRows(transfers: 1, attempts: 1, receipts: 1, on: app)
        }
    }

    @Test(arguments: ["changed", "format", "interval", "route-permission", "stored-limit", "source-limit"])
    func declarationRefusalsPreserveTheOriginalEvidenceAndCreateNoAttempt(reason: String) async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant")) { app, token in
            let fixture = try await Self.prepare(on: app), id = UUID()
            let client = try Self.client(app, token: token)
            var declaration = Self.declaration(fixture)
            if reason == "changed" { _ = try await Self.register(client, fixture: fixture, id: id, declaration: declaration) }
            let expected: HTTPStatus
            switch reason {
            case "changed": declaration.attachmentPath = "recordings/other.csv"; expected = .conflict
            case "format": declaration.format = "unknown-recording"; expected = .badRequest
            case "interval": declaration.effectiveEnd = declaration.effectiveAt.addingTimeInterval(-1); expected = .badRequest
            case "route-permission": declaration.targets[0].consentId = fixture.consentIDs[1].uuidString; expected = .forbidden
            case "stored-limit":
                declaration.content.storedByteCount = Int64(RecordingTransferService.Limits.standard.storedBytes + 1)
                declaration.content.sourceByteCount = declaration.content.storedByteCount
                expected = .payloadTooLarge
            default:
                declaration.content.encoding = .zstd
                declaration.content.sourceByteCount = Int64(RecordingTransferService.Limits.standard.sourceBytes + 1)
                expected = .payloadTooLarge
            }
            try await app.test(.POST, Self.path(fixture, id: id, operation: "declaration"), beforeRequest: {
                $0.bearerAuth(token)
                $0.sourceInstallation(fixture.installationID)
                try Self.setDeclaration(declaration, in: &$0)
            }) { response in
                #expect(response.status == expected)
            }
            try await Self.expectRows(transfers: reason == "changed" ? 1 : 0, attempts: 0, receipts: 0, on: app)
        }
    }

    @Test(arguments: [
        (TestApp.Token.none, HTTPStatus.unauthorized), (.researcher(), .forbidden),
        (.participant(subject: "foreign-participant"), .notFound)
    ])
    func nonownersCannotRegisterUploadOrLookUp(identity: TestApp.Token, status: HTTPStatus) async throws {
        try await TestApp.withApp(token: identity) { app, token in
            let fixture = try await Self.prepare(on: app), id = UUID()
            for (method, operation) in [(HTTPMethod.POST, "declaration"), (.PUT, "content"), (.GET, "receipt")] {
                try await app.test(method, Self.path(fixture, id: id, operation: operation), beforeRequest: {
                    $0.bearerAuth(token)
                    $0.sourceInstallation(fixture.installationID)
                    if method == .POST { try Self.setDeclaration(Self.declaration(fixture), in: &$0) }
                    if method == .PUT { Self.setRecordingBody(&$0) }
                }) { response in
                    #expect(response.status == status)
                }
            }
            try await Self.expectRows(transfers: 0, attempts: 0, receipts: 0, on: app)
        }
    }

    @Test(arguments: ["unknown-declaration", "bad-proof", "length", "encoding"])
    func invalidUploadsNeverReserveAnObject(reason: String) async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant")) { app, token in
            let fixture = try await Self.prepare(on: app), id = UUID()
            if reason != "unknown-declaration" {
                _ = try await Self.register(Self.client(app, token: token), fixture: fixture, id: id, declaration: Self.declaration(fixture))
            }
            try await app.test(.PUT, Self.path(fixture, id: id, operation: "content"), beforeRequest: {
                $0.bearerAuth(token)
                $0.sourceInstallation(reason == "bad-proof" ? UUID() : fixture.installationID)
                Self.setRecordingBody(&$0)
                if reason == "length" { $0.body = .init(bytes: [0]) }
                if reason == "encoding" { $0.headers.replaceOrAdd(name: .contentEncoding, value: "zstd") }
            }) { response in
                let expected: HTTPStatus = reason == "unknown-declaration" ? .notFound : reason == "bad-proof" ? .forbidden : .badRequest
                #expect(response.status == expected)
            }
            try await Self.expectRows(transfers: reason == "unknown-declaration" ? 0 : 1, attempts: 0, receipts: 0, on: app)
        }
    }

    @Test
    func oversizedDeclarationIsRejectedBeforeDecodingOrStateChanges() async throws {
        try await TestApp.withApp(token: .participant(subject: "test-participant")) { app, token in
            let fixture = try await Self.prepare(on: app)
            try await app.test(.POST, Self.path(fixture, id: UUID(), operation: "declaration"), beforeRequest: {
                $0.bearerAuth(token)
                $0.sourceInstallation(fixture.installationID)
                $0.headers.contentType = .json
                $0.body = .init(bytes: Array(repeating: UInt8(32), count: RecordingTransferDeclaration.maximumBytes + 1))
            }) { response in
                #expect(response.status == .payloadTooLarge)
            }
            try await Self.expectRows(transfers: 0, attempts: 0, receipts: 0, on: app)
        }
    }
}


extension RecordingTransferHTTPTests {
    static func prepare(on app: Application) async throws -> ClinicalEventStoreTests.Fixture {
        try await ClinicalEventStoreTests.prepare(on: app, profile: CollectionObservationProfile.workout.rawValue, routeStudies: [0])
    }

    static func declaration(_ fixture: ClinicalEventStoreTests.Fixture) -> Components.Schemas.RecordingTransferDeclaration {
        let date = Date(), digest = ArtifactStore.digest(bytes)
        return .init(
            attachmentPath: "recordings/route.csv",
            outputFullUrl: "urn:uuid:24622144-883b-4f1a-99a6-054f532482b5",
            profile: FHIRRecordingProjection.profile,
            format: FHIRRecordingProjection.routeFormat,
            effectiveAt: date,
            effectiveEnd: date,
            content: .init(
                encoding: .identity,
                storedByteCount: Int64(bytes.count),
                storedSHA256: digest,
                sourceByteCount: Int64(bytes.count),
                sourceSHA256: digest
            ),
            targets: [.init(consentId: fixture.consentIDs[0].uuidString, outputFullUrls: ["urn:uuid:24622144-883b-4f1a-99a6-054f532482b5"])]
        )
    }

    static func client(_ app: Application, token: String?) throws -> TroveAPIClient.Client {
        try .init(serverURL: Servers.Server1.url(), configuration: .trove, transport: ReceiverClientTransport(application: app, token: token))
    }

    static func register(
        _ client: TroveAPIClient.Client,
        fixture: ClinicalEventStoreTests.Fixture,
        id: UUID,
        declaration: Components.Schemas.RecordingTransferDeclaration
    ) async throws -> Components.Schemas.RecordingTransferRegistration {
        try await client.declareParticipantRecordingTransfer(.init(
            path: .init(sourceId: fixture.source.id.uuidString, transferId: id.uuidString),
            headers: .init(
                troveSourceInstallationID: fixture.installationID.uuidString,
                troveSourceCredential: SourceBindingFixture.credentialBase64(fixture.installationID)
            ),
            body: .json(declaration)
        )).ok.body.json
    }

    static func send(_ client: TroveAPIClient.Client, fixture: ClinicalEventStoreTests.Fixture, id: UUID, expectResponseLoss: Bool) async throws {
        do {
            let result = try await client.uploadParticipantRecordingTransfer(.init(
                path: .init(sourceId: fixture.source.id.uuidString, transferId: id.uuidString),
                headers: .init(
                    troveSourceInstallationID: fixture.installationID.uuidString,
                    troveSourceCredential: SourceBindingFixture.credentialBase64(fixture.installationID)
                ),
                body: .binary(.init(bytes))
            ))
            _ = try result.ok
            #expect(!expectResponseLoss)
        } catch {
            guard expectResponseLoss else { throw error }
        }
    }

    static func lookup(
        _ client: TroveAPIClient.Client, fixture: ClinicalEventStoreTests.Fixture, id: UUID
    ) async throws -> Components.Schemas.RecordingTransferReceipt {
        try await client.lookupParticipantRecordingTransferReceipt(.init(
            path: .init(sourceId: fixture.source.id.uuidString, transferId: id.uuidString)
        )).ok.body.json
    }

    static func path(_ fixture: ClinicalEventStoreTests.Fixture, id: UUID, operation: String) -> String {
        "\(apiBasePath)/participant/sources/\(fixture.source.id)/recording-transfers/\(id)/\(operation)"
    }

    private static func setDeclaration(_ declaration: Components.Schemas.RecordingTransferDeclaration, in request: inout TestingHTTPRequest) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(TroveDateTranscoder().encode(date))
        }
        request.headers.contentType = .json
        request.body = .init(data: try encoder.encode(declaration))
    }

    static func setRecordingBody(_ request: inout TestingHTTPRequest) {
        request.headers.contentType = .binary
        request.headers.replaceOrAdd(name: .contentLength, value: String(bytes.count))
        request.body = .init(data: bytes)
    }

    static func expectRows(transfers: Int, attempts: Int, receipts: Int, on app: Application) async throws {
        let sql = try #require(app.db as? any SQLDatabase)
        let counts = [("recording_transfers", transfers), ("recording_transfer_attempts", attempts), ("recording_transfer_receipts", receipts)]
        for (table, expected) in counts {
            let row = try #require(try await sql.raw("SELECT COUNT(*) AS count FROM \(ident: table)").first())
            #expect(try row.decode(column: "count", as: Int.self) == expected)
        }
    }
}


extension Operations.UploadParticipantRecordingTransfer.Output {
    fileprivate var isConflict: Bool {
        if case .conflict = self {
            return true
        }
        return false
    }
}
