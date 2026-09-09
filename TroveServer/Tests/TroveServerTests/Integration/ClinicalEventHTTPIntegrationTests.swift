//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Crypto
import Fluent
import Foundation
import SQLKit
import Testing
import TroveAPIServer
@testable import TroveServer
import VaporTesting


/// This lane requires the real pinned validator, PostgreSQL and object storage.
/// Unlike store unit tests, every admitted event passes full IG/Java validation through HTTP.
struct ClinicalEventHTTPIntegrationTests {
    @Test(.enabled(
        if: Environment.get("TROVE_TEST_VALIDATOR_ASSETS") != nil,
        "Requires the isolated, pinned full-validation integration setup"
    ))
    func oneEventTwoStudiesSafeRetriesWithdrawalAndApplicationRestart() async throws {
        try #require(Environment.get("TROVE_TEST_POSTGRES_PORT") != nil)
        try #require(Environment.get("FHIR_VALIDATOR_URL") != nil && Environment.get("FHIR_VALIDATOR_IDENTITY") != nil)
        let port = try #require(Environment.get("TROVE_TEST_S3_PORT").flatMap(Int.init))
        try #require((1024...65535).contains(port))
        let configuration = S3ObjectStorageConfiguration(
            endpoint: "http://127.0.0.1:\(port)",
            accessKeyId: "trove_test",
            secretAccessKey: "trove_test",
            bucket: "trove-event-test-\(UUID().uuidString.lowercased())",
            region: "us-east-1"
        )
        try await TestApp.withS3Storage(configuration: configuration) { storage in
            try await storage.ensureBucketExists()
            try await TestApp.withApp(token: .participant(subject: "test-participant"), storageProvider: storage) { app, token in
                let fixture = try await ClinicalEventStoreTests.prepare(on: app)
                let bytes = try ImmutablePointEventFixture.bytes(source: fixture.source)
                let receipt = try await Self.upload(bytes, fixture: fixture, token: token, on: app)
                let retry = try await Self.upload(bytes, fixture: fixture, token: token, on: app)
                #expect(receipt == retry)
                try await Self.expectState(fixture, receipt: receipt, bytes: bytes, withdrawn: false, on: app)
                try await Self.expectConflict(bytes + Data(" ".utf8), fixture: fixture, token: token, on: app)
                try await Self.expectConflict(bytes, fixture: fixture, token: token, on: app, oneTarget: true)
                try await app.test(.POST, "\(apiBasePath)/participant/enrollments/\(fixture.enrollmentIDs[0])/withdraw", beforeRequest: {
                    $0.bearerAuth(token)
                }) { response in
                    #expect(response.status == .ok)
                }
                try await Self.expectState(fixture, receipt: receipt, bytes: bytes, withdrawn: true, on: app)
                try await TestDatabase.withRestartedApplication(app) { restarted in
                    let reopenedStorage = try S3ObjectStorageProvider(application: restarted, config: configuration)
                    do {
                        try await configureServices(for: restarted, storageProvider: reopenedStorage, validator: .init(application: restarted))
                        _ = try await TestApp.configureTransport(for: restarted)
                        let afterRestart = try await Self.upload(bytes, fixture: fixture, token: token, on: restarted)
                        #expect(afterRestart == receipt)
                        try await Self.expectState(fixture, receipt: receipt, bytes: bytes, withdrawn: true, on: restarted)
                        try await Self.expectConsentEvidence(fixture, on: restarted)
                    } catch {
                        try? await reopenedStorage.shutdown()
                        throw error
                    }
                    try await reopenedStorage.shutdown()
                }
            }
        }
    }
}


extension ClinicalEventHTTPIntegrationTests {
    private static func path(_ fixture: ClinicalEventStoreTests.Fixture) -> String {
        "\(apiBasePath)/participant/sources/\(fixture.source.id)/events"
    }

    private static func submission(
        _ bytes: Data, fixture: ClinicalEventStoreTests.Fixture, oneTarget: Bool = false
    ) throws -> Components.Schemas.EventSubmission {
        let event = try FHIRPointProjection.project(validatedBytes: bytes, validatorIdentity: "test-framing-only")
        let targets = fixture.targets(for: event, studies: oneTarget ? [0] : [0, 1])
        return .init(eventBase64: bytes.base64EncodedString(), targets: targets.map {
            .init(consentId: $0.consentID.uuidString, outputFullUrls: $0.outputFullURLs)
        })
    }

    private static func upload(
        _ bytes: Data, fixture: ClinicalEventStoreTests.Fixture, token: String?, on app: Application
    ) async throws -> Components.Schemas.EventReceipt {
        var receipt: Components.Schemas.EventReceipt?
        try await app.test(.POST, path(fixture), beforeRequest: { request in
            request.bearerAuth(token)
            try request.encodeJSONBody(submission(bytes, fixture: fixture))
        }) { response in
            try #require(response.status == .ok)
            receipt = try response.content.decode(Components.Schemas.EventReceipt.self)
        }
        return try #require(receipt)
    }

    private static func expectConflict(
        _ bytes: Data, fixture: ClinicalEventStoreTests.Fixture, token: String?, on app: Application, oneTarget: Bool = false
    ) async throws {
        try await app.test(.POST, path(fixture), beforeRequest: { request in
            request.bearerAuth(token)
            try request.encodeJSONBody(submission(bytes, fixture: fixture, oneTarget: oneTarget))
        }) { response in
            #expect(response.status == .conflict)
        }
    }

    private static func expectState(
        _ fixture: ClinicalEventStoreTests.Fixture, receipt: Components.Schemas.EventReceipt, bytes: Data, withdrawn: Bool, on app: Application
    ) async throws {
        let bundle = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let identifier = try #require(bundle["identifier"] as? [String: Any])
        #expect(receipt.producerEventIdentifier.system == identifier["system"] as? String)
        #expect(receipt.producerEventIdentifier.value == identifier["value"] as? String)
        #expect(receipt.payloadSHA256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        try await ClinicalEventStoreTests.expectRows(events: 1, nodes: receipt.nodeCount, facts: 1, grants: 2, on: app.db)
        let store = ClinicalEventStore(database: app.db)
        #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[0]) == (withdrawn ? 0 : 1))
        #expect(try await store.effectiveGrantCount(studyID: fixture.studyIDs[1]) == 1)
        let sql = try #require(app.db as? any SQLDatabase)
        let row = try #require(try await sql.raw("SELECT raw_bytes FROM clinical_events").first())
        #expect(try row.decode(column: "raw_bytes", as: Data.self) == bytes)
    }

    private static func expectConsentEvidence(_ fixture: ClinicalEventStoreTests.Fixture, on app: Application) async throws {
        try await AuthContext.$current.withValue(ClinicalEventStoreTests.participant) {
            let service = app.grove[ConsentService.self]
            let records = try await service.listConsents(enrollmentId: fixture.enrollmentIDs[1])
            let consent = try #require(records.first)
            let evidence = try await service.getConsentPDF(enrollmentId: fixture.enrollmentIDs[1], consentId: consent.requireID())
            #expect(evidence == Data("%PDF-1.4 Synthetic consent evidence".utf8))
        }
    }
}
